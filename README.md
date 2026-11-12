# 🪲 Micro Wild : Survival (Roblox)

Un jeu de survie, d'évolution et de PvP à l'échelle microscopique sur **Roblox**. Incarnez l'une des **30 espèces d'insectes** (terrestres, volants, aquatiques), naissez sous forme d'**œuf** dans un nid protégé par une **Maman / Colonie**, évoluez en larve puis en adulte, survivez aux **4 saisons** et affrontez (ou chassez) **5 animaux géants** !

📄 **[Voir la Fiche de Conception Complète (GDD)](./docs/GAME_DESIGN_DOCUMENT.md)**

---

## 📁 Structure Rojo du Projet (Identique à `Battelgrounds`)

```text
micro-wild-roblox/
├── default.project.json                      # Configuration Rojo
├── wally.toml                                # Gestionnaire de packages Wally
├── Packages/                                 # ReplicatedStorage.shared.packages
├── ServerPackages/                           # ServerScriptService.serverPackages
├── docs/
│   └── GAME_DESIGN_DOCUMENT.md               # Fiche complète du projet
└── src/
    ├── shared/                               # ReplicatedStorage.shared
    │   ├── InsectData.luau                   # Les 30 insectes, régimes, stats et pouvoirs
    │   ├── AnimalData.luau                   # Les 5 animaux géants (Oiseau, Caméléon, Poisson, Crabe, Écureuil)
    │   └── SeasonConfig.luau                 # Configuration des 4 saisons et températures
    ├── server/                               # ServerScriptService
    │   ├── bootstrap/
    │   │   └── ServerBootstrap.server.luau   # Point d'entrée serveur
    │   ├── constant/
    │   │   └── GameConstants.luau            # Constantes de survie et paliers d'évolution
    │   ├── data/
    │   │   └── PlayerDataRepository.luau     # Attributs et données des joueurs
    │   ├── domain/
    │   │   └── EvolutionDomain.luau          # Logique métier : Œuf -> Larve -> Cocon/Mue -> Adulte
    │   ├── services/
    │   │   ├── SurvivalService.luau          # Faim, Soif, Température, Oxygène
    │   │   ├── GrowthAndNestService.luau     # Système de Maman/Nid et Croissance
    │   │   └── SeasonService.luau            # Cycle des 4 saisons
    │   ├── types/
    │   │   └── ServerTypes.luau              # Types Luau serveur
    │   └── utils/
    │       └── MathUtils.luau                # Fonctions utilitaires
    ├── client/                               # StarterPlayer.StarterPlayerScripts
    │   ├── bootstrap/
    │   │   └── ClientBootstrap.client.luau   # Point d'entrée client
    │   ├── controllers/
    │   │   └── AbilityController.luau        # Contrôles des pouvoirs (E, R) et chasse (F)
    │   ├── managers/
    │   │   └── UIManager.luau                # Gestionnaire d'interfaces
    │   ├── state/
    │   │   └── ClientState.luau              # État client
    │   └── views/
    │       └── SurvivalHudView.luau          # Affichage HUD (Faim, Soif, Température, Stade)
    ├── clientCharacter/                      # StarterPlayer.StarterCharacterScripts
    │   ├── charactercontrollers/
    │   │   └── WallClimbController.client.luau # Escalade 360° sur les murs, arbres et feuilles
    │   └── characterstate/
    │       └── CharacterState.luau           # État du personnage (grimpe, vol, nage)
    └── starterFirst/                         # ReplicatedFirst.startFirst
        └── LoadingScreen.client.luau         # Chargement initial
```
