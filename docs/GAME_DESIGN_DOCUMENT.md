# 🪲 FICHE DE CONCEPTION DE JEU (GDD) : MICRO WILD : SURVIVAL

**Plateforme :** Roblox
**Genre :** Survie / Simulation Animale / RPG / PvP / Sandbox
**Inspirations :** *Creatures of Sonaria*, *Empires of the Undergrowth*, *Grounded*, *The Isle*

---

## 1. 🎯 Vision & Concept Principal

**Micro Wild : Survival** plonge les joueurs à l'échelle microscopique dans un écosystème géant, vivant et impitoyable. Chaque joueur commence sa vie sous forme d'**œuf** dans un nid ou une colonie, protégé par une **Maman (joueuse ou IA)**. Il doit éclore, survivre à l'état de larve, accomplir sa métamorphose ou ses mues comme dans la vraie vie, gérer sa faim, sa soif et sa température à travers **4 saisons dynamiques**, tout en échappant (ou en chassant !) **5 animaux géants** et en affrontant d'autres joueurs avec des capacités réalistes.

---

## 2. 🐣 Cycle de Vie, Maman & Évolution Réaliste

Chaque insecte suit un cycle biologique fidèle à la réalité :

### Étape 1 : L'Œuf (0% -> 10% de croissance)
* **Spawn :** Le joueur choisit soit de naître dans le nid d'une **Maman joueuse** (qui a créé un nid/colonie), soit dans un nid protégé par une **IA**.
* **Mécanique :** L'œuf doit rester à la bonne température. Si le nid est attaqué, la Maman ou la colonie doit le défendre (ou transporter l'œuf pour les fourmis !).

### Étape 2 : Larve / Nymphe / Chenille (10% -> 50% de croissance)
* **Dépendance :** À l'éclosion, le joueur est une larve (ou nymphe/jeune). Il ne peut pas encore quitter la zone du nid/de la mare.
* **Nourrissage :** La Maman (et les ouvrières de la colonie) rapporte de la nourriture au nid pour nourrir les bébés et accélérer leur évolution.
* **Spécificité par espèce :**
  * *Abeille / Fourmi / Mouche :* Larve blanche nourrie dans la colonie.
  * *Papillon :* Chenille qui doit dévorer les feuilles de l'arbre natal.
  * *Libellule / Moustique / Éphémère :* Larve aquatique qui grandit sous l'eau avant de sortir à la surface.

### Étape 3 : Métamorphose ou Mue (50% -> 75% de croissance)
* **Insectes à métamorphose complète (Holométaboles)** *(Papillon, Abeille, Frelon, Scarabée, Mouche, Fourmi, Coccinelle, Phrygane)* :
  * Le joueur doit trouver un endroit sûr et caché pour **tisser un cocon / chrysalide / nymphe**.
  * Pendant 30 à 45 secondes, il est immobile mais très résistant. À la sortie, il débloque ses ailes et sa forme finale !
* **Insectes à mue progressive (Hémimétaboles & Arachnides)** *(Mante, Araignée, Scorpion, Sauterelle, Phasme, Punaise d'eau)* :
  * Le joueur grandit par paliers et doit **muer** (changer de peau). Pendant quelques secondes après la mue, sa carapace est molle (vulnérable), puis durcit et augmente ses statistiques.

### Étape 4 : Adulte & Reproduction (75% -> 100%+)
* **Liberté totale :** Le joueur peut quitter le nid natal, explorer toute la carte, chasser, faire du PvP et utiliser 100% de ses pouvoirs.
* **Devenir Maman / Reine :** À 100% de croissance, un joueur peut construire un nid ou fonder une colonie pour accueillir d'autres joueurs en tant qu'œufs (gagne de l'XP et des Points d'Évolution).

---

## 3. 🌡️ Système de Survie (Besoins Vitaux)

| Besoin | Fonctionnement | Conséquence si négligé |
| :--- | :--- | :--- |
| **Faim** | Dépend du régime : **Herbivore** (feuilles, pollen, nectar, sève, bois), **Carnivore** (insectes, larves, poissons, sang), **Omnivore** (fruits, graines, miettes, viande, champignons). | Perte de régénération d'endurance, puis perte de points de vie. |
| **Soif** | Boire dans les **gouttes de rosée** (sur les plantes) ou dans la **mare/rivière** (zone dangereuse avec poissons et crabes). | Ralentissement, vision trouble, perte de vie. |
| **Température** | **Froid** (Nuit / Hiver / Eau profonde) vs **Chaud** (Soleil d'été / Pierres brûlantes). | **Hypothermie :** Vitesse réduite de 50%, impossibilité de voler.<br>**Surchauffe :** Soif qui descend 3x plus vite. |
| **Oxygène** | Concerne les insectes qui plongent sous l'eau. Certains ont des branchies (illimité), d'autres transportent une **bulle d'air** (Dytique, Argyronète) ou un tuba (Nèpe). | Noyade progressive. |

---

## 4. 🗺️ La Grande Map & Les 4 Saisons

### Les Biomes de la Carte
1. **Le Grand Chêne :** Un arbre titanesque où l'on peut grimper des racines jusqu'à la cime (nids d'oiseaux, territoire de l'écureuil et du caméléon, ruches d'abeilles).
2. **La Mare & Le Ruisseau :** Un monde sous-marin complet (roseaux, vase, galets) habité par les insectes aquatiques, le poisson rouge et le crabe.
3. **La Prairie Fleurie :** Hautes herbes géantes, fleurs riches en nectar, toiles d'araignées tendues entre les tiges.
4. **La Souche Pourrie & Les Galeries Souterraines :** Réseau de tunnels sombres (fourmilières, termitières, terriers d'araignées), idéal pour survivre à l'hiver.
5. **Le Coin des Rochers Arides :** Pierres chaudes au soleil, territoire des scorpions, scolopendres et scarabées bombardiers.

### Le Cycle des 4 Saisons (15-20 min par saison)
* 🌸 **Printemps :** Éclosion rapide (+25% vitesse de croissance), fleurs abondantes, gouttes de rosée partout, averses de pluie (les gouttes tombent comme des bombes d'eau !).
* ☀️ **Été :** Journées longues et chaudes, bonus d'endurance pour les insectes volants, assèchement des petites flaques (oblige tout le monde à boire à la grande mare = zone PvP intense).
* 🍁 **Automne :** Chute de fruits géants (pommes, baies, glands) qui nourrissent des dizaines d'insectes, vents forts qui poussent les insectes en vol, feuilles mortes au sol pour se camoufler.
* ❄️ **Hiver :** Neige au sol, froid glacial à l'extérieur, la surface de la mare gèle (les insectes aquatiques vivent sous la glace). Les joueurs terrestres doivent se réfugier sous terre, dans l'écorce des arbres ou se regrouper en colonie pour partager leur chaleur.

---

## 5. 🐞 Les 30 Insectes (Terrestres, Volants, Aquatiques)

Chaque insecte possède ses **capacités réelles de déplacement** (escalade des murs/arbres à la verticale et au plafond grâce à ses griffes/ventouses) et ses **pouvoirs naturels**.

### A. Terrestres (12 espèces)
| # | Espèce | Régime | Déplacement spécial | Pouvoirs & Capacités Réelles |
| :- | :--- | :--- | :--- | :--- |
| **1** | **Fourmi Rousse** | Omnivore | Grimpe murs/arbres | **Jet d'acide formique** (distance), **Phéromones** (alerte la colonie), porte des objets très lourds. |
| **2** | **Mante Religieuse** | Carnivore | Grimpe arbres + petit vol | **Camouflage végétal**, **Pattes ravisseuses** (saisit et bloque une proie instantanément). |
| **3** | **Lucane Cerf-Volant** | Herbivore (Sève) | Grimpe troncs + vol lourd | **Pinces géantes** (soulève un ennemi et le jette dans le vide depuis une branche), carapace blindée. |
| **4** | **Scarabée Hercule** | Herbivore (Fruits/Bois) | Grimpe + vol lourd | **Charge corne**, insecte le plus fort et résistant au corps-à-corps. |
| **5** | **Veuve Noire** | Carnivore | Grimpe partout + fil de soie | **Construction de toile piège** (immobilise les joueurs qui touchent), **Venin neurotoxique** mortel. |
| **6** | **Araignée Sauteuse** | Carnivore | Grimpe partout + fil de sécurité | **Super-bond ciblé** (saute sur les proies même en vol bas), vision à 360°. |
| **7** | **Scorpion Empereur** | Carnivore | Terrestre + creuse le sable | **Double pince** (maintient l'ennemi) + **Coup de dard venimeux**, résiste à la chaleur d'été. |
| **8** | **Sauterelle / Criquet** | Herbivore | Grimpe tiges + saut géant | **Catapulte** (saute par-dessus les obstacles), coup de pattes arrière éjecteur. |
| **9** | **Coccinelle** | Carnivore | Grimpe partout + vol | **Saignement réflexe** (dégage un liquide jaune toxique qui repousse et aveugle l'attaquant). |
| **10** | **Termite Soldat** | Herbivore (Bois) | Grimpe + creuse le bois | **Canon frontal à glu** (tire une colle collante qui ralentit les ennemis de 80%). |
| **11** | **Scolopendre Géante** | Carnivore | Ultra-rapide + grimpe rochers | **Course sinueuse**, **Crochets venimeux**, peut s'enrouler autour d'une proie pour l'étouffer. |
| **12** | **Phasme Bâton** | Herbivore | Grimpe branches | **Mimétisme absolu** (devient 100% indiscernable d'une branche d'arbre quand immobile). |

### B. Volants (10 espèces)
| # | Espèce | Régime | Déplacement spécial | Pouvoirs & Capacités Réelles |
| :- | :--- | :--- | :--- | :--- |
| **13** | **Abeille Mellifère** | Herbivore (Pollen) | Vol + marche murs | **Fabrication de miel** (soigne toute la ruche), **Piqûre kamikaze** (dégâts énormes + poison). |
| **14** | **Frelon Asiatique** | Carnivore | Vol stationnaire rapide | **Attaque en piqué**, **Mandibules coupeuses**, **Marquage de cible** pour appeler l'essaim. |
| **15** | **Libellule Empereur** | Carnivore | Nage (larve) puis Vol 360° | **Reine du ciel** (vol avant, arrière, côté à très haute vitesse), capture les insectes en plein vol. |
| **16** | **Papillon Monarque** | Herbivore (Nectar) | Grimpe (chenille) puis Vol plané | **Toxine naturelle** (tout prédateur qui le mord subit du poison), endurance de vol immense. |
| **17** | **Moustique Tigre** | Omnivore / Sang | Nage (larve) puis Vol furtif | **Succion de sang** (boit le sang des 5 animaux géants ou gros insectes pour gagner un boost d'XP). |
| **18** | **Luciole** | Carnivore (larve) | Vol nocturne + grimpe | **Bioluminescence** (éclaire les grottes et la nuit, **Flash lumineux** pour éblouir un prédateur). |
| **19** | **Mouche / Taon** | Omnivore / Sang | Marche plafond + vol nerveux | **Vision ralentie (Réflexe)** : esquive automatiquement une attaque, odorat longue portée. |
| **20** | **Scarabée Bombardier**| Carnivore | Grimpe + petit vol | **Explosion chimique bouillante** : tire un spray explosif à 100°C par l'abdomen ! |
| **21** | **Cigale** | Herbivore (Sève) | Souterrain (larve) puis Vol | **Cymbalisation (Cri sonique)** : onde sonore qui fait vibrer l'écran et étourdit les ennemis proches. |
| **22** | **Guêpe Émeraude** | Carnivore | Vol agile + grimpe | **Piqûre de contrôle mental** : inverse les touches de déplacement d'un joueur ennemi pendant 5s ! |

### C. Aquatiques & Semi-Aquatiques (8 espèces)
| # | Espèce | Régime | Déplacement spécial | Pouvoirs & Capacités Réelles |
| :- | :--- | :--- | :--- | :--- |
| **23** | **Gerris (Patineur)** | Carnivore | **Marche sur l'eau** | Glisse à haute vitesse sur l'eau, **Radar à vibrations** (détecte tout insecte tombé à l'eau). |
| **24** | **Dytique Bordé** | Carnivore | Nage rapide + Vol nocturne | **Bulle d'oxygène**, **Mâchoires de requin** (excellent pour chasser les petits poissons en groupe). |
| **25** | **Nèpe (Scorpion d'eau)**| Carnivore | Marche au fond de l'eau | **Tuba respiratoire**, **Camouflage feuille morte** dans la vase, pattes avant en piège à loup. |
| **26** | **Notonecte** | Carnivore | Nage sur le dos + Vol | **Rameur ultra-rapide**, **Rostre piqueur** (inflige une douleur vive même aux gros poissons). |
| **27** | **Larve de Phrygane** | Omnivore | Marche sous l'eau + Vol (adulte)| **Architecte blindé** : ramasse du sable et des brindilles pour se créer un fourreau-armure (+80% défense). |
| **28** | **Argyronète** | Carnivore | Nage + Toile sous-marine | **Cloche de plongée** : tisse une bulle d'air sous l'eau où elle peut respirer, stocker sa nourriture et pondre ! |
| **29** | **Éphémère** | Herbivore | Nage (branchies) puis Vol | **Sprint aquatique**, fouisseur de vase (introuvable par le poisson rouge quand enterré). |
| **30** | **Punaise d'eau géante (Lethocerus)** | Carnivore | Nage + Marche + Vol | **Le Monstre de la Mare** : injecte des enzymes digestives, **peut chasser et tuer des poissons** en solo ! |

---

## 6. 🦎 Les 5 Petits Animaux (Prédateurs Majeurs & Chasse)

Ces 5 créatures donnent l'impression d'être face à des **Monstres Géants (Kaijus)**. Ils patrouillent dans leurs zones respectives.

1. 🐦 **L'Oiseau (Rouge-Gorge / Martin-Pêcheur)**
   * **Comportement :** Se pose sur les branches et au sol. S'il voit un insecte bouger à découvert, il fond dessus à grande vitesse.
   * **Interaction :** Impossible à tuer seul, mais les frelons/abeilles peuvent lui piquer les yeux pour le faire fuir.
2. 🦎 **Le Caméléon**
   * **Comportement :** Grimpe lentement dans le Grand Chêne en changeant de couleur. Ses yeux tournent dans tous les sens.
   * **Attaque :** **Langue grappin** ultra-rapide ! Si tu es dans son champ de vision à moyenne portée, il te colle et t'avale (un allié peut mordre la langue pour te libérer !).
3. 🐠 **Le Poisson Rouge (et Bancs d'Alevins)**
   * **Comportement :** Nage dans la mare. Les **petits poissons (alevins)** peuvent être chassés par la *Punaise d'eau géante*, le *Dytique*, la *Nèpe* ou la *Larve de Libellule*.
   * **Le Gros Poisson Rouge :** Un boss aquatique qui aspire les insectes proches et saute hors de l'eau. Si une meute d'insectes aquatiques réussit à le vaincre, il donne de la nourriture pour tout le serveur !
4. 🦀 **Le Crabe de Rivière**
   * **Comportement :** Patrouille au fond de l'eau et sur les berges rocheuses.
   * **Interaction :** Sa carapace est impénétrable de face et ses pinces tuent en un coup. Mais une colonie de fourmis ou de dytiques peut l'attaquer par l'arrière (articulations) pour le chasser !
5. 🐿️ **L'Écureuil Roux**
   * **Comportement :** Bondit de branche en branche dans le Grand Chêne (provoque des tremblements d'écran pour les insectes sur l'arbre !).
   * **Interaction :** Cherche des glands et des fruits. En cassant des noix et des fruits géants, il laisse tomber plein de miettes nutritives pour les insectes herbivores/omnivores.

---

## 7. ⚔️ Systèmes de Gameplay Avancés (Roblox Studio)

### 1. Système d'Escalade "Spider-Walk" (Raycasting)
* Les insectes qui grimpent dans la vraie vie (Fourmis, Araignées, Mouches, Coléoptères, Mantes) s'alignent automatiquement avec la surface qu'ils touchent : troncs d'arbres verticaux, dessous des feuilles, plafonds des grottes.
* **Avantage tactique :** Une araignée ou une mante peut attendre la tête en bas sous une feuille et se laisser tomber sur un joueur qui passe en dessous !

### 2. Système de Colonie & de Maman
* **Création de Nid :** Un insecte adulte construit un nid (Fourmilière, Ruche, Toile maternelle, Cocon d'œufs de mante).
* **Menu de Spawn :** À la connexion, le joueur voit la liste des Mamans actives sur le serveur (ex: *"Reine Fourmi [12 ouvrières]"*, *"Maman Veuve Noire [3 bébés]"*).
* **Coopération :** Les membres d'une même famille voient une icône au-dessus de leurs frères/sœurs et de leur Maman, ne se font pas de dégâts entre eux (Friendly Fire désactivé dans le clan) et partagent le stock de nourriture du nid.

### 3. Système de Chasse & PvP
* **Combat dynamique :**
  * **Clic Gauche :** Morsure / Coup de griffe.
  * **Touche F (Agripper) :** Permet aux prédateurs (Mante, Punaise d'eau, Dytique, Scorpion, Araignée) d'immobiliser un poisson ou un insecte plus petit. La proie doit appuyer rapidement sur Espace (QTE) pour tenter de se libérer !
  * **Touches E & R :** Compétences spéciales de l'espèce (Toile, Venin, Acide, Flash, Camouflage, Cri sonique).
  * **Transport de proie :** Une fois un poisson ou un insecte chassé, on peut le porter dans ses mandibules pour le ramener au nid et nourrir les larves !

---

## 8. 📅 Plan de Développement Recommandé (Étapes pour créer le jeu)

1. **Prototype (Étape 1) :**
   * Coder le contrôleur d'insecte (marche normale + marche sur les murs/arbres + vol).
   * Créer le système de croissance : **Œuf -> Larve -> Cocon/Mue -> Adulte**.
2. **Survie & Map (Étape 2) :**
   * Ajouter les jauges de **Faim (Herbivore/Carnivore/Omnivore)**, **Soif** et **Température**.
   * Construire une première zone (ex: Autour de la Mare + 1 Grand Arbre) avec le changement des **4 Saisons**.
3. **Premiers Insectes & Chasse (Étape 3) :**
   * Intégrer 6 premiers insectes (2 terrestres, 2 volants, 2 aquatiques : ex. *Fourmi, Mante, Abeille, Libellule, Dytique, Punaise d'eau*).
   * Ajouter le **Poisson Rouge** (et les petits poissons à chasser) + l'**Oiseau**.
4. **Expansion Complète (Étape 4) :**
   * Ajouter le reste des **30 insectes** et les **5 animaux** (*Caméléon, Crabe, Écureuil*).
   * Ajouter les **Colonies**, les **Mutations rares (Skins)** et les classements PvP.
