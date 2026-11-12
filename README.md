# 🪲 Micro Wild : Survival (Roblox)

Un jeu de survie, d'évolution et de PvP à l'échelle microscopique sur **Roblox**. Incarnez l'une des **30 espèces d'insectes** (terrestres, volants, aquatiques), naissez sous forme d'**œuf** dans un nid protégé par une **Maman / Colonie**, évoluez en larve puis en adulte, survivez aux **4 saisons** et affrontez (ou chassez) **5 animaux géants** !

📄 **[Voir la Fiche de Conception Complète (GDD)](./docs/GAME_DESIGN_DOCUMENT.md)**

---

## 🌟 Fonctionnalités Principales

* 🐣 **Cycle de Vie Réaliste :** `Œuf` ➔ `Larve / Nymphe / Chenille` ➔ `Cocon / Mue` ➔ `Adulte & Reine/Maman`.
* 🌡️ **Survie Complète :**
  * **Régimes alimentaires :** Herbivore, Carnivore, Omnivore, Hématophage (sang).
  * **Soif :** Gouttes de rosée ou mare (zone à haut risque).
  * **Température :** Hypothermie (nuit/hiver) et Surchauffe (été).
  * **Oxygène :** Bulle d'air sous-marine, tuba respiratoire ou branchies.
* 🍂 **Grande Carte & 4 Saisons Dynamiques :** Printemps, Été, Automne, Hiver (la mare gèle en hiver, les flaques s'assèchent en été).
* 🕷️ **30 Espèces d'Insectes :**
  * **12 Terrestres** (*Fourmi Rousse, Mante Religieuse, Lucane, Scarabée Hercule, Veuve Noire, Araignée Sauteuse, Scorpion, Sauterelle, Coccinelle, Termite Soldat, Scolopendre, Phasme*).
  * **10 Volants** (*Abeille, Frelon Asiatique, Libellule, Papillon Monarque, Moustique, Luciole, Mouche/Taon, Scarabée Bombardier, Cigale, Guêpe Émeraude*).
  * **8 Aquatiques** (*Gerris, Dytique, Nèpe, Notonecte, Larve de Phrygane, Argyronète, Éphémère, Punaise d'eau géante*).
* 🦎 **5 Petits Animaux (Boss / Prédateurs & Chasse) :**
  * 🐦 **Oiseau** | 🦎 **Caméléon** | 🐠 **Poisson Rouge (+ alevins à chasser)** | 🦀 **Crabe** | 🐿️ **Écureuil**.
* 🧗 **Physique Réaliste :** Escalade à 360° sur les murs, les troncs d'arbres et sous les feuilles, tissage de toiles, vol stationnaire et marche sur l'eau.

---

## 📁 Architecture du Projet (Rojo / Roblox Studio)

```text
micro-wild-roblox/
├── default.project.json          # Configuration Rojo pour synchroniser avec Roblox Studio
├── docs/
│   └── GAME_DESIGN_DOCUMENT.md   # Fiche complète du projet
└── src/
    ├── ReplicatedStorage/
    │   └── Shared/
    │       ├── InsectData.luau   # Les 30 insectes, régimes, stats et pouvoirs
    │       ├── AnimalData.luau   # Les 5 animaux géants (Oiseau, Caméléon, Poisson, Crabe, Écureuil)
    │       └── SeasonConfig.luau # Configuration des 4 saisons et températures
    ├── ServerScriptService/
    │   └── Server/
    │       ├── SurvivalManager.server.luau # Faim, Soif, Température, Oxygène
    │       ├── GrowthAndNest.server.luau   # Système d'Œuf, Maman, Larve, Cocon/Mue
    │       └── SeasonManager.server.luau   # Cycle des 4 saisons sur le serveur
    └── StarterPlayer/
        └── StarterCharacterScripts/
            └── WallClimbController.client.luau # Grimpe aux murs, arbres et plafonds
```

---

## 🚀 Comment utiliser ce projet dans Roblox Studio

1. **Avec Rojo (Recommandé) :**
   * Installez le plugin **Rojo** dans Roblox Studio.
   * Lancez `rojo serve` dans ce dossier et connectez Roblox Studio.
2. **Manuellement :**
   * Copiez les scripts du dossier `src/ReplicatedStorage/Shared` dans `ReplicatedStorage`.
   * Copiez les scripts de `src/ServerScriptService/Server` dans `ServerScriptService`.
   * Copiez le script de `src/StarterPlayer/StarterCharacterScripts` dans `StarterPlayer > StarterCharacterScripts`.
