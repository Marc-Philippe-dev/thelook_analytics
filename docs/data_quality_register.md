# Registre des anomalies — theLook eCommerce

**Source** : `bigquery-public-data.thelook_ecommerce`
**Projet** : `thelook-analytics-509323` (région US, sandbox)
**Profilage** : 1er octobre 2026
**Requêtes** : `docs/profiling.bqnb`
**Auteur** : Marc Philippe Gnancadja

---

## 0. Avertissement : la source est régénérée quotidiennement

Entre deux exécutions à 24 h d'intervalle, les volumes ont changé :

| Table | 30/09 | 01/10 | Écart |
|---|---:|---:|---:|
| `events` | 2 419 854 | 2 418 876 | −978 |
| `inventory_items` | 488 244 | 486 972 | −1 272 |
| `order_items` | 180 771 | 180 245 | −526 |
| `orders` | 124 814 | 124 280 | −534 |
| `users` | 100 000 | 100 000 | 0 |
| `products` | 29 120 | 29 120 | 0 |

Les tables transactionnelles sont **régénérées**, pas seulement complétées. Les
dimensions (`users`, `products`, `distribution_centers`) sont stables.

**Conséquences pour la suite**
- Tout chiffre de ce registre est daté du **1er octobre 2026**.
- Un backfill rejoué un autre jour ne produira pas les mêmes lignes : l'ingestion
  de la phase 2 doit figer un instantané dans `raw`, et c'est lui qui fera foi.
- Les tests dbt doivent porter sur `raw`, jamais directement sur la source publique.

---

## 1. Inventaire de la source

| Table | Lignes | Taille (Mo) | Remarque |
|---|---:|---:|---|
| `events` | 2 418 876 | 366,4 | **3× tout le reste réuni** : seule table qui justifie un partitionnement |
| `inventory_items` | 486 972 | 77,0 | ~16,7 exemplaires par référence du catalogue |
| `users` | 100 000 | 18,9 | |
| `order_items` | 180 245 | 12,9 | 1,45 article par commande |
| `orders` | 124 280 | 6,4 | |
| `products` | 29 120 | 4,1 | |
| `distribution_centers` | 10 | 0,0 | table de référence |

**Fraîcheur** : toutes les tables portent le même `last_modified`, le 01/10/2026
vers 04:00 UTC. Rechargement en bloc.

**Coût** : 0 octet traité. `__TABLES__` ne lit que des métadonnées.
---
![](/docs/images/profiling/task_1.png)
---

## 2. Modèle relationnel

**17 colonnes** se terminent par `id`, réparties en 7 clés primaires, 9 clés
étrangères donc potentiellemment 9 relations et 1 faux positif.

| # | Table enfant | Colonne | Table parente | Statut |
|---|---|---|---|---|
| R1 | `orders` | `user_id` | `users.id` | ✅ validée (§4) |
| R2 | `order_items` | `order_id` | `orders.order_id` | ✅ validée |
| R3 | `order_items` | `user_id` | `users.id` | ✅ validée — **redondante avec R1** |
| R4 | `order_items` | `product_id` | `products.id` | ✅ validée |
| R5 | `order_items` | `inventory_item_id` | `inventory_items.id` | ✅ validée, **1–1** |
| R6 | `inventory_items` | `product_id` | `products.id` | non testée |
| R7 | `inventory_items` | `product_distribution_center_id` | `distribution_centers.id` | non testée — dénormalisation |
| R8 | `products` | `distribution_center_id` | `distribution_centers.id` | ✅ validée |
| R9 | `events` | `user_id` | `users.id` | non testée |

**Faux positif** : `events.session_id` se termine par `id` mais ne pointe vers
aucune table. C'est un identifiant de session de navigation.

**Enseignement de méthode** : une détection par convention de nommage retrouve 8
relations sur 9. `product_distribution_center_id` échappe à toute heuristique :
son préfixe indique la **provenance** de la donnée, pas la table cible.

**Grain de `order_items`** : un **article physique vendu**. Une commande de trois
articles identiques produit trois lignes.
---
![](/docs/images/profiling/task_2.0.png)
![](/docs/images/profiling/task_2.1.png)
---

 

## 3. Clés primaires — unicité et nullité ✅ aucune anomalie

| Clé | Lignes | Distinctes | Nulles | Doublons | Verdict |
|---|---:|---:|---:|---:|---|
| `distribution_centers.id` | 10 | 10 | 0 | 0 | ✅ |
| `inventory_items.id` | 486 972 | 486 972 | 0 | 0 | ✅ |
| `order_items.id` | 180 245 | 180 245 | 0 | 0 | ✅ |
| `orders.order_id` | 124 280 | 124 280 | 0 | 0 | ✅ |
| `products.id` | 29 120 | 29 120 | 0 | 0 | ✅ |
| `users.id` | 100 000 | 100 000 | 0 | 0 | ✅ |

**Décision** : les six colonnes sont des clés primaires fiables.
**Tests dbt** : `unique` + `not_null` sur chacune.
---
![](/docs/images/profiling/task_3.0.png)
---

## 4. Intégrité référentielle ✅ aucun orphelin

| Contrôle | Résultat |
|---|---:|
| `order_items` (total) | 180 245 |
| → sans commande | **0** |
| → sans produit | **0** |
| → sans client | **0** |
| → sans exemplaire en stock | **0** |
| `orders` sans aucune ligne | **0** |
| `products` sans centre de distribution | **0** |

**Décision** : les jointures R1 à R5 et R8 ne perdent aucune ligne. Aucun
traitement correctif nécessaire.
**Tests dbt** : `relationships` sur chaque clé étrangère.

**Reste à tester** : R6, R7 et R9 (`inventory_items` → `products` et
`distribution_centers`, `events` → `users`).

<!-- PLACEHOLDER IMAGE : docs/images/t4_integrite.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t4_sens_inverse.png -->

---

## 5. Cohérence temporelle ⚠️ anomalie majeure

### 5a. `order_items`

| Contrôle | Lignes | % du total |
|---|---:|---:|
| `shipped_at` < `created_at` | **35 555** | **19,7 %** |
| `delivered_at` < `shipped_at` | 0 | 0 % |
| `returned_at` < `delivered_at` | 0 | 0 % |
| `created_at` dans le futur | **1 623** | 0,9 % |
| `delivered_at` dans le futur | **1 839** | 1,0 % |
| `created_at` avant 1900 | à relire (colonne tronquée) | |

### 5b. `orders` — comparaison des deux niveaux

| Contrôle | Lignes |
|---|---:|
| Total | 124 280 |
| `shipped_at` < `created_at` | **0** |
| `delivered_at` < `shipped_at` | **0** |
| `created_at` dans le futur | **0** |

**Constat central** : l'en-tête de commande est parfaitement cohérent, la ligne
ne l'est pas. L'anomalie est donc introduite à la génération des lignes, pas des
commandes. Rapporté aux seules lignes disposant d'un `shipped_at` (117 526, soit
Shipped + Complete + Returned), le taux d'anomalie monte à **30 %**.

### 5c. Ampleur de l'écart

La distribution des écarts négatifs commence à **−95 heures**, soit près de
4 jours d'expédition « avant » la commande, avec 35 à 177 lignes par tranche
horaire. Ce n'est donc pas un décalage de fuseau horaire ni une erreur
d'arrondi : c'est un défaut du générateur de données.

**Décision proposée** : neutraliser `shipped_at` (mettre à `NULL`) quand il
précède `created_at`, et ne jamais calculer de délai d'expédition sur ces lignes.
À confirmer avant la phase 3.
**Test dbt** : test singulier qui échoue si une ligne de `fct_order_items`
présente un délai d'expédition négatif.

### 5d. Période couverte

| Première commande | Dernière commande | Jours couverts |
|---|---|---:|
| 2019-01-11 | **2026-10-05** | 2 824 |

La dernière date est **postérieure à la date du profilage** (01/10/2026), ce qui
confirme les 1 623 lignes créées dans le futur. Le générateur produit des
commandes jusqu'à quelques jours en avance.

**Conséquence phase 2** : un backfill sur 2 824 jours est hors de proportion pour
un sandbox. Charger les 90 derniers jours, et documenter ce choix.

<!-- PLACEHOLDER IMAGE : docs/images/t5a_dates_order_items.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t5b_dates_orders.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t5c_ampleur_ecart.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t5d_periode.png -->

---

## 6. Statuts et cohérence métier ✅ aucune incohérence

### 6a. Distribution des statuts de `order_items`

| Statut | Lignes | % |
|---|---:|---:|
| Shipped | 54 689 | 30,34 |
| Complete | 44 839 | 24,88 |
| Processing | 35 826 | 19,88 |
| Cancelled | 26 893 | 14,92 |
| Returned | 17 998 | 9,99 |

Cinq statuts, aucune valeur aberrante ni variante de casse.
**Test dbt** : `accepted_values` sur ces cinq valeurs.

### 6b. En-tête contre ligne

Cinq combinaisons seulement, toutes diagonales : le statut de la commande est
**toujours** celui de ses lignes. Aucune divergence.

**Conséquence** : `orders.status` est une donnée redondante. En Silver, on peut
la dériver des lignes ou la conserver telle quelle, mais il faut un test qui
détecte une future divergence.

### 6c. `num_of_item` contre le nombre réel de lignes

| Commandes | Concordantes | Discordantes |
|---:|---:|---:|
| 124 280 | **124 280** | **0** |

Le compteur est fiable à 100 %.

### 6d. Statut contre dates renseignées

| Statut | `shipped_at` manquant | `delivered_at` manquant | A un `returned_at` | Lignes |
|---|---:|---:|---:|---:|
| Shipped | 0 | 54 689 | 0 | 54 689 |
| Complete | 0 | 0 | 0 | 44 839 |
| Processing | 35 826 | 35 826 | 0 | 35 826 |
| Cancelled | 26 893 | 26 893 | 0 | 26 893 |
| Returned | 0 | 0 | 17 998 | 17 998 |

**Lecture** : la correspondance est parfaite. Expédié mais pas livré, complet
donc livré, en cours donc aucune date, annulé donc aucune date, retourné donc
livré puis retourné. Le cycle de vie est parfaitement déterministe.

**Test dbt** : test singulier vérifiant que chaque statut porte bien les dates
attendues, ni plus ni moins.

### Règle métier du chiffre d'affaires net

> **À écrire avant la phase 3.** Les statuts `Cancelled` (14,92 %) et `Returned`
> (9,99 %) sortent manifestement du CA net. La question ouverte est le traitement
> de `Processing` (19,88 %), commandé mais pas encore expédié : CA engagé ou non ?
> Trancher, et appliquer la même règle en dbt et en LookML.

<!-- PLACEHOLDER IMAGE : docs/images/t6a_statuts.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t6b_statuts_croises.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t6c_num_of_item.png -->
<!-- PLACEHOLDER IMAGE : docs/images/t6d_statuts_dates.png -->

---

## 7. Coût et facturation

Relevé depuis les métadonnées des jobs du notebook.

| Requête | Octets traités | Octets facturés | Cache |
|---|---:|---:|---|
| Inventaire via `__TABLES__` | 0 | 0 | non |
| `INFORMATION_SCHEMA.COLUMNS` | 10 Mo | 10 Mo | non |
| Intégrité référentielle | — | — | **oui** |
| Cohérence `order_items` | 2,89 Mo | **10 Mo** | non |
| Cohérence `orders` | 1,90 Mo | **10 Mo** | non |
| Distribution des écarts | 2,27 Mo | **10 Mo** | non |
| Période couverte | 1,38 Mo | **10 Mo** | non |
| Statut contre dates | 3,27 Mo | **10 Mo** | non |

**Trois enseignements**
1. **Facturation minimale de 10 Mo par requête.** Toutes ces requêtes traitent
   entre 1,4 et 3,3 Mo et sont pourtant facturées 10 Mo. Optimiser sous ce seuil
   ne rapporte rien.
2. **Les métadonnées ne se valent pas** : `__TABLES__` est gratuit,
   `INFORMATION_SCHEMA.COLUMNS` a bien été facturé 10 Mo.
3. **Le cache est gratuit**, valable 24 h, invalidé dès que la table change — ce
   qui, ici, arrive chaque nuit (voir §0).

**À compléter** : comparaison `SELECT *` contre trois colonnes sur `events`
(366 Mo), seule table assez volumineuse pour dépasser le seuil des 10 Mo et
rendre l'effet du stockage en colonnes visible.

<!-- PLACEHOLDER IMAGE : docs/images/t8_cout_comparaison.png -->

---

## 8. Décisions structurantes pour la phase 2

| Sujet | Décision |
|---|---|
| Colonne de partition | `created_at` (candidat principal) |
| Profondeur du backfill | 90 derniers jours — 2 824 jours serait disproportionné |
| Tables en incrémental | `orders`, `order_items`, `events`, `users` |
| Tables en full | `products`, `distribution_centers`, `inventory_items` (à confirmer) |
| Instantané figé | Obligatoire : la source change chaque nuit (§0) |
| Grain de `fct_order_items` | Un article physique vendu |
| Colonnes écartées de Gold | PII de `users` (nom, prénom, email, adresse) ; colonnes `product_*` dupliquées dans `inventory_items` |

---

## 9. Synthèse des tests dbt à écrire en phase 3

| Modèle | Colonne | Test | Origine |
|---|---|---|---|
| `stg_thelook__users` | `id` | `unique`, `not_null` | §3 |
| `stg_thelook__orders` | `order_id` | `unique`, `not_null` | §3 |
| `stg_thelook__orders` | `user_id` | `relationships` → users | §4 |
| `stg_thelook__order_items` | `id` | `unique`, `not_null` | §3 |
| `stg_thelook__order_items` | `inventory_item_id` | `unique`, `not_null` | §2, R5 |
| `stg_thelook__order_items` | `order_id` | `relationships` → orders | §4 |
| `stg_thelook__order_items` | `product_id` | `relationships` → products | §4 |
| `stg_thelook__order_items` | `status` | `accepted_values` (5 valeurs) | §6a |
| `stg_thelook__products` | `id` | `unique`, `not_null` | §3 |
| `stg_thelook__products` | `distribution_center_id` | `relationships` | §4 |
| `stg_thelook__inventory_items` | `id` | `unique`, `not_null` | §3 |
| (singulier) | délai d'expédition négatif | test personnalisé | §5a |
| (singulier) | statut incohérent avec les dates | test personnalisé | §6d |
| (singulier) | divergence statut en-tête / ligne | test personnalisé | §6b |

---

## 10. Bilan de la phase 1

**Trois anomalies réelles**, toutes dans les dates de `order_items` :
19,7 % de lignes expédiées avant d'être créées, 0,9 % créées dans le futur,
1,0 % livrées dans le futur.

**Tout le reste est sain** : clés uniques et non nulles, aucun orphelin, statuts
cohérents entre les deux niveaux, compteur d'articles exact.

**Le vrai piège n'était pas une anomalie de données** mais la volatilité de la
source : elle est régénérée chaque nuit, ce qui impose de figer un instantané dès
l'ingestion.
