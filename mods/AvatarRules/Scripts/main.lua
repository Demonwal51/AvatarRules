-- Avatar Rules (Spirit City: Lofi Sessions): "when these conditions are true, the avatar does this".
-- Everything runs on the game thread, from the camera pawn's tick. No LoopAsync.
--
-- Two traps this file is built around, both measured in the real game:
-- 1. Never call anything from Lua that may load an asset synchronously (the outfit change does). The loading thread
--    waits on a UE4SS lock held by the Lua call, the game thread waits on the loading thread, and the game freezes
--    ("Loading is stuck, flush will never finish"). The outfit is changed by an engine timer on the game's own preset
--    button: the game then makes the call itself, with no Lua on the stack.
-- 2. The preset button assumes the avatar editor is open: it moves the camera to the wardrobe and hides the avatar.
--    Going back into the current activity right after puts everything back.

local function dossier_du_mod()
    local ok, source = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and source then
        local d = source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/[^/]*$")
        if d then return d end
    end
    return "ue4ss/Mods/AvatarRules/"
end
local DOSSIER = dossier_du_mod()
local FICHIER_REGLES = DOSSIER .. "regles.txt"
local FICHIER_JOURNAL = DOSSIER .. "journal.txt"

-- The test bridge exists only on a development install: dev.txt holds its folder. A released mod has no such file.
local PONT = nil
do
    local f = io.open(DOSSIER .. "dev.txt", "r")
    if f then
        PONT = f:read("*l")
        f:close()
    end
end

do
    local f = io.open(FICHIER_JOURNAL, "w")
    if f then f:close() end
end
local function journal(texte)
    local f = io.open(FICHIER_JOURNAL, "a")
    if f then
        f:write(os.date("%H:%M:%S "), texte, "\n")
        f:close()
    end
end

local function valide(o) return o ~= nil and o:IsValid() end

-- ---------------------------------------------------------------- what the game offers
local TABLE_TEXTES = "/Game/Core_Sessions/ST_Localization.ST_Localization"
local TABLE_ACTIVITES = "/Game/Core_Sessions/Activities/DATA_LocationActivities.DATA_LocationActivities"
local BIB_DLC = "/Game/Core_Sessions/PlayerProgression/BPFL_FilterContent.Default__BPFL_FilterContent_C"

-- Places, in the order of the game's maps. dlc is the game's own ownership check: a place the player does not own is never offered.
local ENDROITS = {
    { id = "Desk", carte = "Bedroom", cle = "RelatedLocation_Desk" },
    { id = "Bed", carte = "Bedroom", cle = "RelatedLocation_Bed" },
    { id = "Baywindow", carte = "Bedroom", cle = "RelatedLocation_Baywindow" },
    { id = "Fireplace", carte = "Bedroom", cle = "RelatedLocation_Fireplace" },
    { id = "Kitchen", carte = "Bedroom", cle = "RelatedLocation_Kitchen", dlc = "Kitchen" },
    { id = "Train_Interior", carte = "Train", cle = "RelatedLocation_TrainInterior", dlc = "Train" },
    { id = "Train_Exterior", carte = "Train", cle = "RelatedLocation_TrainExterior", dlc = "Train" },
    { id = "Garden_Interior", carte = "Garden", cle = "RelatedLocation_Interior", dlc = "Garden" },
    { id = "Garden_Exterior", carte = "Garden", cle = "RelatedLocation_Exterior", dlc = "Garden" },
    { id = "Garden_Gazebo", carte = "Garden", cle = "RelatedLocation_Gazebo", dlc = "Garden" },
    { id = "Library_Foyer", carte = "Library", cle = "RelatedLocation_Foyer", dlc = "Library" },
    { id = "Library_Study", carte = "Library", cle = "RelatedLocation_StudyDesk", dlc = "Library" },
    { id = "Library_Nook", carte = "Library", cle = "RelatedLocation_Nook", dlc = "Library" },
    { id = "Library_Arcana", carte = "Library", cle = "RelatedLocation_Arcana", dlc = "Library" },
}
local ENDROIT_PAR_ID = {}
for _, e in ipairs(ENDROITS) do ENDROIT_PAR_ID[e.id] = e end

-- The row names of the game's activity table, by place, with the key of their name in the game's text table.
local ACTIVITES = {
    Desk = { { "Typing", "Typing" }, { "Gaming", "Gaming" }, { "Drawing", "Drawing" }, { "Writing", "Writing" }, { "Painting", "Painting" } },
    Bed = { { "Browsing", "Browsing" }, { "Relaxing", "Relaxing" }, { "Gaming", "Gaming" }, { "Reading", "Reading" } },
    Baywindow = { { "Reading", "Reading" }, { "Knitting", "Knitting" }, { "LookingOut", "LookingOutside" }, { "Typing", "Typing" }, { "Meditating", "Meditating" }, { "Cleaning", "Cleaning" }, { "Exercising", "Exercising" }, { "Music", "Music" } },
    Fireplace = { { "Writing", "Writing" }, { "Knitting", "Knitting" }, { "Gaming", "Gaming" }, { "Typing", "Typing" }, { "Reading", "Reading" }, { "Sipping", "Sipping" }, { "Playing", "PlayingWithSpirit" } },
    Kitchen = { { "Dishes", "Dishes" }, { "Cooking", "Cooking" }, { "Grilling", "Grilling" }, { "Baking", "Baking" }, { "Eating", "Eating" }, { "Mealprep", "Mealprep" }, { "Typing", "Typing" }, { "Reading", "Reading" } },
    Train_Interior = { { "Typing", "Typing" }, { "Sipping", "Sipping" }, { "Knitting", "Knitting" }, { "Drawing", "Drawing" }, { "Writing", "Writing" }, { "Sleeping", "Sleeping" }, { "Reading", "Reading" }, { "Looking", "LookingOutside" }, { "Gaming", "Gaming" }, { "Photo", "TakingPhotos" } },
    Train_Exterior = { { "Looking", "LookingOutside" }, { "Photo", "TakingPhotos" }, { "Gaming", "Gaming" }, { "Reading", "Reading" }, { "Sipping", "Sipping" } },
    Garden_Interior = { { "Watering", "Watering" }, { "Planting", "Planting" }, { "Botany", "Botany" }, { "Writing", "Writing" }, { "Typing", "Typing" }, { "Painting", "Painting" } },
    Garden_Exterior = { { "Watering", "Watering" }, { "Harvesting", "Harvesting" }, { "Planting", "Planting" }, { "Reading", "Reading" }, { "Meditating", "Meditating" }, { "Stretching", "Exercising" }, { "Relaxing", "Relaxing" }, { "Playing", "PlayingWithSpirit" }, { "Sipping", "Sipping" } },
    Garden_Gazebo = { { "Music", "Music" }, { "Painting", "Painting" }, { "Gaming", "Gaming" }, { "Knitting", "Knitting" }, { "Drawing", "Drawing" }, { "Sipping", "Sipping" } },
    Library_Foyer = { { "Reading", "Reading" }, { "Sipping", "Sipping" }, { "Relaxing", "Relaxing" }, { "Knitting", "Knitting" }, { "Writing", "Writing" }, { "Browsing", "BrowsingBook" }, { "Music", "Music" }, { "Gaming", "Gaming" }, { "Playing", "PlayingWithSpirit" } },
    Library_Study = { { "Studying", "Studying" }, { "Reading", "Reading" }, { "Dactylo", "TypingDactylo" }, { "Typing", "Typing" }, { "Botany", "Botany" }, { "Sipping", "Sipping" }, { "Cleaning", "Cleaning" }, { "Sleeping", "Sleeping" }, { "Writing", "Writing" }, { "Plotting", "Plotting" } },
    Library_Nook = { { "Reading", "Reading" }, { "Looking", "LookingOutside" }, { "Browsing", "BrowsingBook" }, { "Writing", "Writing" }, { "Playing", "PlayingWithSpirit" }, { "Knitting", "Knitting" }, { "Typing", "Typing" } },
    Library_Arcana = { { "Spellcasting", "Spellcasting" }, { "Cauldron", "Cauldron" }, { "Summoning", "Summoning" }, { "ElementalMagic", "ElementalMagic" } },
}
local NOMBRE_PROFILS = 10
local NOMBRE_DECORS = 5
local APPLIS = { connues = false, ouvertes = {}, liste = {}, ecrans = {}, prochain = 0 }

-- ---------------------------------------------------------------- the player's rules
-- A rule is true when at least one of its conditions is true ("or"). Inside one condition, everything must be true ("and").
-- "Then" and "else" are lists of steps, done in order, each one after its own wait.
local REGLES = {}

local function rempli(x) return x ~= nil and x ~= "" end

local function nouvelle_condition()
    return { de = "8:00", a = "12:00", jours = "tous", annee = "", pomodoro = "", musique = "", appli = "", plan = "", ecran = "" }
end

local function nouvelle_etape()
    return { attente = "0", profil = "", endroit = "", activite = "", decor = "", musique = "" }
end

local function nouvelle_regle()
    return {
        actif = "1", inverse = "0",
        fin = "rien",  -- when it ends: rien (nothing) or avant (as it was before)
        -- Kept across a restart, so a rule that ends while the game is closed can still put things back.
        en_cours = "0", avant_profil = "", avant_rang = "", avant_decor = "", avant_musique = "",
        pose_profil = "", pose_rang = "", pose_decor = "", pose_musique = "",
        conditions = { nouvelle_condition() }, alors = { nouvelle_etape() }, sinon = {},
    }
end

local CHAMPS_REGLE = { "actif", "inverse", "fin", "en_cours", "avant_profil", "avant_rang", "avant_decor", "avant_musique", "pose_profil", "pose_rang", "pose_decor", "pose_musique" }
local CHAMPS_CONDITION = { "de", "a", "jours", "annee", "pomodoro", "musique", "appli", "plan", "ecran" }
local CHAMPS_ETAPE = { "attente", "profil", "endroit", "activite", "decor", "musique" }

local function lire_regles()
    local f = io.open(FICHIER_REGLES, "r")
    if not f then return end
    local regle, objet = nil, nil
    for ligne in f:lines() do
        ligne = ligne:gsub("\r$", "")
        local cle, valeur = ligne:match("^([%a_]+)=(.*)$")
        if cle == "regle" then
            regle = nouvelle_regle()
            regle.conditions, regle.alors, regle.sinon = {}, {}, {}
            REGLES[#REGLES + 1] = regle
            objet = regle
        elseif regle and cle == "condition" then
            objet = nouvelle_condition()
            regle.conditions[#regle.conditions + 1] = objet
        elseif regle and cle == "etape_alors" then
            objet = nouvelle_etape()
            regle.alors[#regle.alors + 1] = objet
        elseif regle and cle == "etape_sinon" then
            objet = nouvelle_etape()
            regle.sinon[#regle.sinon + 1] = objet
        elseif cle and objet and type(objet[cle]) == "string" then
            objet[cle] = valeur
        end
    end
    f:close()
    -- A rule always has one condition and one step to show.
    for _, r in ipairs(REGLES) do
        if #r.conditions == 0 then r.conditions[1] = nouvelle_condition() end
        if #r.alors == 0 then r.alors[1] = nouvelle_etape() end
    end
end

local function ecrire_regles()
    local tmp = FICHIER_REGLES .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    local function champs(objet, liste)
        for _, cle in ipairs(liste) do f:write(cle, "=", tostring(objet[cle] or ""), "\n") end
    end
    for _, r in ipairs(REGLES) do
        f:write("regle=\n")
        champs(r, CHAMPS_REGLE)
        for _, c in ipairs(r.conditions) do
            f:write("condition=\n")
            champs(c, CHAMPS_CONDITION)
        end
        for _, e in ipairs(r.alors) do
            f:write("etape_alors=\n")
            champs(e, CHAMPS_ETAPE)
        end
        for _, e in ipairs(r.sinon) do
            f:write("etape_sinon=\n")
            champs(e, CHAMPS_ETAPE)
        end
    end
    f:close()
    os.remove(FICHIER_REGLES)
    os.rename(tmp, FICHIER_REGLES)
end

-- ---------------------------------------------------------------- the game's objects
local GARDES = {}
local function objet_garde(classe)
    local t = os.clock()
    local g = GARDES[classe]
    if g and t < g.jusqua and g.objet:IsValid() then return g.objet end
    GARDES[classe] = nil
    for _, o in ipairs(FindAllOf(classe) or {}) do
        if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then
            GARDES[classe] = { objet = o, jusqua = t + 5 }
            return o
        end
    end
    return nil
end
local function hud() return objet_garde("UI_BedroomHUD_C") end
local function gestion_lieu() return objet_garde("BP_LocationActivityManager_C") end
local function gestion_tenue() return objet_garde("BP_AvatarCustomizationManager_C") end
local function gestion_cartes() return objet_garde("BP_MapManager_C") end

-- The game's own ownership check. If it cannot answer, the place is not offered.
local DLC_CONNUS = {}
local function possede(dlc)
    if not dlc then return true end
    if DLC_CONNUS[dlc] ~= nil then return DLC_CONNUS[dlc] end
    local reponse = false
    local ok, err = pcall(function()
        local bib = StaticFindObject(BIB_DLC)
        local monde = gestion_lieu()
        local sortie = {}
        bib["Does own " .. dlc .. " DLC?"](bib, monde, sortie)
        reponse = sortie["Own " .. dlc .. " DLC"] == true
    end)
    if not ok then journal("DLC " .. dlc .. " : pas de reponse : " .. tostring(err)) end
    journal("DLC " .. dlc .. " : " .. tostring(reponse))
    DLC_CONNUS[dlc] = reponse
    return reponse
end

-- ---------------------------------------------------------------- texts
local TEXTES = {
    en = {
        onglet = "Rules", section = "RULES", regle_t = "Rule", regle_d = "Pick the rule to change, or create a new one", nom = "Rule %d", nouvelle = "New rule", aucune = "No rule yet",
        actif_t = "Rule on", actif_d = "A rule acts when its condition changes. In between, you are free to do something else",
        de_t = "From", de_d = "The time the rule acts", a_t = "Until", a_d = "After this time the rule is ready again for the next day",
        tenue_t = "Then: outfit", tenue_d = "The outfit preset to wear", laisser = "No change", profil = "Preset %d",
        endroit_t = "Then: go to", endroit_d = "The place to go to", activite_t = "Then: do", activite_d = "The activity to do there",
        avance_t = "Advanced functions", avance_d = "More conditions, decor, music, end of the rule, and else",
        journee = "All day", jours_t = "Days", jours_d = "The days the rule can act", tous_jours = "Every day", semaine = "Monday to Friday", weekend = "Weekend",
        jour_noms = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" },
        essayer_t = "Try this rule", essayer_d = "Closes the options and does it now, whatever the conditions say", essayer_rien = "—", essayer_alors = "Try: then", essayer_sinon = "Try: else",
        annee_t = "Time of year", annee_d = "Seasons of the northern half of the world. Months work everywhere", toute_annee = "All year",
        saisons = { printemps = "Spring", ete = "Summer", automne = "Autumn", hiver = "Winter" },
        mois_noms = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
        pomodoro_t = "Pomodoro", pomodoro_d = "The state of the game's Pomodoro timer", peu_importe = "Any", p_travail = "Working", p_pause = "On a break", p_arrete = "Stopped",
        musique_si_t = "Music is", musique_si_d = "The state of the game's music player", m_lecture = "Playing", m_pause = "Paused",
        decor_t = "Then: room preset", decor_d = "The decor preset of the place where the avatar is", musique_t = "Then: music", musique_d = "The game's music player", m_suivante = "Next track",
        sens_t = "Condition", sens_d = "The rule can act when these conditions are true, or when they are not", si = "If it is true", si_non = "If it is not true",
        fin_t = "When the rule ends", fin_d = "When the condition stops being true. What you changed yourself is left alone", fin_rien = "Do nothing", fin_avant = "Put things back",
        s_tenue_t = "Else: outfit", s_tenue_d = "When the condition is not true", s_endroit_t = "Else: go to", s_endroit_d = "When the condition is not true", s_activite_t = "Else: do", s_activite_d = "The activity to do there",
        suppr_t = "Delete this rule", suppr_d = "Pick Yes to delete it", oui = "Yes", non = "No",
        Bedroom = "Bedroom", Train = "Train", Garden = "Garden", Library = "Library",
    },
    fr = {
        onglet = "Règles", section = "RÈGLES", regle_t = "Règle", regle_d = "Choisissez la règle à modifier, ou créez-en une nouvelle", nom = "Règle %d", nouvelle = "Nouvelle règle", aucune = "Aucune règle",
        actif_t = "Règle active", actif_d = "Une règle agit quand sa condition change. Entre-temps, vous êtes libre de faire autre chose",
        de_t = "À partir de", de_d = "L'heure où la règle agit", a_t = "Jusqu'à", a_d = "Après cette heure, la règle est de nouveau prête pour le lendemain",
        tenue_t = "Alors : tenue", tenue_d = "Le profil de tenue à mettre", laisser = "Ne pas changer", profil = "Profil %d",
        endroit_t = "Alors : aller à", endroit_d = "L'endroit où aller", activite_t = "Alors : faire", activite_d = "L'activité à y faire",
        avance_t = "Fonctions avancées", avance_d = "Autres conditions, décor, musique, fin de la règle et sinon",
        journee = "Toute la journée", jours_t = "Jours", jours_d = "Les jours où la règle peut agir", tous_jours = "Tous les jours", semaine = "Du lundi au vendredi", weekend = "Le week-end",
        jour_noms = { "Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi" },
        essayer_t = "Essayer cette règle", essayer_d = "Ferme les options et le fait tout de suite, quelles que soient les conditions", essayer_rien = "—", essayer_alors = "Essayer : alors", essayer_sinon = "Essayer : sinon",
        annee_t = "Moment de l'année", annee_d = "Saisons de l'hémisphère nord. Les mois marchent partout", toute_annee = "Toute l'année",
        saisons = { printemps = "Printemps", ete = "Été", automne = "Automne", hiver = "Hiver" },
        mois_noms = { "Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Août", "Septembre", "Octobre", "Novembre", "Décembre" },
        pomodoro_t = "Pomodoro", pomodoro_d = "L'état du minuteur Pomodoro du jeu", peu_importe = "Peu importe", p_travail = "En travail", p_pause = "En pause", p_arrete = "Arrêté",
        musique_si_t = "Musique", musique_si_d = "L'état du lecteur de musique du jeu", m_lecture = "En lecture", m_pause = "En pause",
        decor_t = "Alors : décor", decor_d = "Le profil de décor de l'endroit où est l'avatar", musique_t = "Alors : musique", musique_d = "Le lecteur de musique du jeu", m_suivante = "Piste suivante",
        sens_t = "Condition", sens_d = "La règle peut agir quand ces conditions sont vraies, ou quand elles ne le sont pas", si = "Si c'est vrai", si_non = "Si ce n'est pas vrai",
        fin_t = "À la fin de la règle", fin_d = "Quand la condition n'est plus vraie. Ce que vous avez changé vous-même n'est pas touché", fin_rien = "Ne rien faire", fin_avant = "Remettre comme avant",
        s_tenue_t = "Sinon : tenue", s_tenue_d = "Quand la condition n'est pas vraie", s_endroit_t = "Sinon : aller à", s_endroit_d = "Quand la condition n'est pas vraie", s_activite_t = "Sinon : faire", s_activite_d = "L'activité à y faire",
        suppr_t = "Supprimer cette règle", suppr_d = "Choisissez Oui pour la supprimer", oui = "Oui", non = "Non",
        Bedroom = "Chambre", Train = "Train", Garden = "Jardin", Library = "Bibliothèque",
    },
    it = {
        onglet = "Regole", section = "REGOLE", regle_t = "Regola", regle_d = "Scegli la regola da modificare o creane una nuova", nom = "Regola %d", nouvelle = "Nuova regola", aucune = "Nessuna regola",
        actif_t = "Regola attiva", actif_d = "Una regola agisce quando la sua condizione cambia. Nel frattempo sei libero di fare altro",
        de_t = "Dalle", de_d = "L'ora in cui la regola agisce", a_t = "Fino alle", a_d = "Dopo quest'ora la regola è di nuovo pronta per il giorno dopo",
        tenue_t = "Allora: abito", tenue_d = "Il profilo d'abito da indossare", laisser = "Non cambiare", profil = "Profilo %d",
        endroit_t = "Allora: vai a", endroit_d = "Il luogo dove andare", activite_t = "Allora: fai", activite_d = "L'attività da fare lì",
        avance_t = "Funzioni avanzate", avance_d = "Altre condizioni, arredamento, musica, fine della regola e altrimenti",
        journee = "Tutto il giorno", jours_t = "Giorni", jours_d = "I giorni in cui la regola può agire", tous_jours = "Tutti i giorni", semaine = "Da lunedì a venerdì", weekend = "Fine settimana",
        jour_noms = { "Domenica", "Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato" },
        essayer_t = "Prova questa regola", essayer_d = "Chiude le opzioni e lo fa subito, qualunque siano le condizioni", essayer_rien = "—", essayer_alors = "Prova: allora", essayer_sinon = "Prova: altrimenti",
        annee_t = "Periodo dell'anno", annee_d = "Stagioni dell'emisfero nord. I mesi valgono ovunque", toute_annee = "Tutto l'anno",
        saisons = { printemps = "Primavera", ete = "Estate", automne = "Autunno", hiver = "Inverno" },
        mois_noms = { "Gennaio", "Febbraio", "Marzo", "Aprile", "Maggio", "Giugno", "Luglio", "Agosto", "Settembre", "Ottobre", "Novembre", "Dicembre" },
        pomodoro_t = "Pomodoro", pomodoro_d = "Lo stato del timer Pomodoro del gioco", peu_importe = "Qualsiasi", p_travail = "Al lavoro", p_pause = "In pausa", p_arrete = "Fermo",
        musique_si_t = "Musica", musique_si_d = "Lo stato del lettore musicale del gioco", m_lecture = "In riproduzione", m_pause = "In pausa",
        decor_t = "Allora: arredamento", decor_d = "Il profilo d'arredamento del luogo in cui si trova l'avatar", musique_t = "Allora: musica", musique_d = "Il lettore musicale del gioco", m_suivante = "Brano successivo",
        sens_t = "Condizione", sens_d = "La regola può agire quando queste condizioni sono vere o quando non lo sono", si = "Se è vero", si_non = "Se non è vero",
        fin_t = "Alla fine della regola", fin_d = "Quando la condizione non è più vera. Ciò che hai cambiato tu non viene toccato", fin_rien = "Non fare nulla", fin_avant = "Rimetti com'era",
        s_tenue_t = "Altrimenti: abito", s_tenue_d = "Quando la condizione non è vera", s_endroit_t = "Altrimenti: vai a", s_endroit_d = "Quando la condizione non è vera", s_activite_t = "Altrimenti: fai", s_activite_d = "L'attività da fare lì",
        suppr_t = "Elimina questa regola", suppr_d = "Scegli Sì per eliminarla", oui = "Sì", non = "No",
        Bedroom = "Camera", Train = "Treno", Garden = "Giardino", Library = "Biblioteca",
    },
    de = {
        onglet = "Regeln", section = "REGELN", regle_t = "Regel", regle_d = "Wähle die Regel, die du ändern willst, oder erstelle eine neue", nom = "Regel %d", nouvelle = "Neue Regel", aucune = "Noch keine Regel",
        actif_t = "Regel aktiv", actif_d = "Eine Regel handelt, wenn sich ihre Bedingung ändert. Dazwischen kannst du frei etwas anderes tun",
        de_t = "Ab", de_d = "Die Uhrzeit, zu der die Regel handelt", a_t = "Bis", a_d = "Nach dieser Uhrzeit ist die Regel für den nächsten Tag wieder bereit",
        tenue_t = "Dann: Outfit", tenue_d = "Das Outfit-Profil, das getragen wird", laisser = "Nicht ändern", profil = "Profil %d",
        endroit_t = "Dann: gehe zu", endroit_d = "Der Ort, an den es geht", activite_t = "Dann: mache", activite_d = "Die Aktivität an diesem Ort",
        avance_t = "Erweiterte Funktionen", avance_d = "Weitere Bedingungen, Einrichtung, Musik, Ende der Regel und Sonst",
        journee = "Ganzer Tag", jours_t = "Tage", jours_d = "Die Tage, an denen die Regel handeln kann", tous_jours = "Jeden Tag", semaine = "Montag bis Freitag", weekend = "Wochenende",
        jour_noms = { "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag" },
        essayer_t = "Diese Regel testen", essayer_d = "Schließt die Optionen und führt sie sofort aus, egal was die Bedingungen sagen", essayer_rien = "—", essayer_alors = "Testen: dann", essayer_sinon = "Testen: sonst",
        annee_t = "Jahreszeit", annee_d = "Jahreszeiten der Nordhalbkugel. Monate gelten überall", toute_annee = "Ganzes Jahr",
        saisons = { printemps = "Frühling", ete = "Sommer", automne = "Herbst", hiver = "Winter" },
        mois_noms = { "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" },
        pomodoro_t = "Pomodoro", pomodoro_d = "Der Zustand des Pomodoro-Timers im Spiel", peu_importe = "Egal", p_travail = "Arbeit", p_pause = "Pause", p_arrete = "Gestoppt",
        musique_si_t = "Musik", musique_si_d = "Der Zustand des Musikplayers im Spiel", m_lecture = "Läuft", m_pause = "Pausiert",
        decor_t = "Dann: Einrichtung", decor_d = "Das Einrichtungsprofil des Ortes, an dem der Avatar ist", musique_t = "Dann: Musik", musique_d = "Der Musikplayer im Spiel", m_suivante = "Nächster Titel",
        sens_t = "Bedingung", sens_d = "Die Regel kann handeln, wenn diese Bedingungen wahr sind oder wenn sie es nicht sind", si = "Wenn es wahr ist", si_non = "Wenn es nicht wahr ist",
        fin_t = "Am Ende der Regel", fin_d = "Wenn die Bedingung nicht mehr wahr ist. Was du selbst geändert hast, bleibt unberührt", fin_rien = "Nichts tun", fin_avant = "Wie vorher",
        s_tenue_t = "Sonst: Outfit", s_tenue_d = "Wenn die Bedingung nicht wahr ist", s_endroit_t = "Sonst: gehe zu", s_endroit_d = "Wenn die Bedingung nicht wahr ist", s_activite_t = "Sonst: mache", s_activite_d = "Die Aktivität an diesem Ort",
        suppr_t = "Diese Regel löschen", suppr_d = "Wähle Ja, um sie zu löschen", oui = "Ja", non = "Nein",
        Bedroom = "Schlafzimmer", Train = "Zug", Garden = "Garten", Library = "Bibliothek",
    },
    es = {
        onglet = "Reglas", section = "REGLAS", regle_t = "Regla", regle_d = "Elige la regla que quieres cambiar o crea una nueva", nom = "Regla %d", nouvelle = "Nueva regla", aucune = "Ninguna regla",
        actif_t = "Regla activa", actif_d = "Una regla actúa cuando cambia su condición. Mientras tanto, eres libre de hacer otra cosa",
        de_t = "Desde", de_d = "La hora en que actúa la regla", a_t = "Hasta", a_d = "Después de esta hora, la regla vuelve a estar lista para el día siguiente",
        tenue_t = "Entonces: ropa", tenue_d = "El perfil de ropa que se pone", laisser = "No cambiar", profil = "Perfil %d",
        endroit_t = "Entonces: ir a", endroit_d = "El lugar al que ir", activite_t = "Entonces: hacer", activite_d = "La actividad que hacer allí",
        avance_t = "Funciones avanzadas", avance_d = "Otras condiciones, decoración, música, fin de la regla y si no",
        journee = "Todo el día", jours_t = "Días", jours_d = "Los días en que la regla puede actuar", tous_jours = "Todos los días", semaine = "De lunes a viernes", weekend = "Fin de semana",
        jour_noms = { "Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado" },
        essayer_t = "Probar esta regla", essayer_d = "Cierra las opciones y lo hace ahora, digan lo que digan las condiciones", essayer_rien = "—", essayer_alors = "Probar: entonces", essayer_sinon = "Probar: si no",
        annee_t = "Época del año", annee_d = "Estaciones del hemisferio norte. Los meses sirven en todas partes", toute_annee = "Todo el año",
        saisons = { printemps = "Primavera", ete = "Verano", automne = "Otoño", hiver = "Invierno" },
        mois_noms = { "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre" },
        pomodoro_t = "Pomodoro", pomodoro_d = "El estado del temporizador Pomodoro del juego", peu_importe = "Da igual", p_travail = "Trabajando", p_pause = "En descanso", p_arrete = "Detenido",
        musique_si_t = "Música", musique_si_d = "El estado del reproductor de música del juego", m_lecture = "Reproduciendo", m_pause = "En pausa",
        decor_t = "Entonces: decoración", decor_d = "El perfil de decoración del lugar donde está el avatar", musique_t = "Entonces: música", musique_d = "El reproductor de música del juego", m_suivante = "Pista siguiente",
        sens_t = "Condición", sens_d = "La regla puede actuar cuando estas condiciones son ciertas o cuando no lo son", si = "Si es cierto", si_non = "Si no es cierto",
        fin_t = "Al terminar la regla", fin_d = "Cuando la condición deja de ser cierta. Lo que hayas cambiado tú no se toca", fin_rien = "No hacer nada", fin_avant = "Dejarlo como estaba",
        s_tenue_t = "Si no: ropa", s_tenue_d = "Cuando la condición no es cierta", s_endroit_t = "Si no: ir a", s_endroit_d = "Cuando la condición no es cierta", s_activite_t = "Si no: hacer", s_activite_d = "La actividad que hacer allí",
        suppr_t = "Eliminar esta regla", suppr_d = "Elige Sí para eliminarla", oui = "Sí", non = "No",
        Bedroom = "Dormitorio", Train = "Tren", Garden = "Jardín", Library = "Biblioteca",
    },
    pt = {
        onglet = "Regras", section = "REGRAS", regle_t = "Regra", regle_d = "Escolha a regra que quer alterar ou crie uma nova", nom = "Regra %d", nouvelle = "Nova regra", aucune = "Nenhuma regra",
        actif_t = "Regra ativa", actif_d = "Uma regra age quando sua condição muda. Enquanto isso, você fica livre para fazer outra coisa",
        de_t = "A partir de", de_d = "O horário em que a regra age", a_t = "Até", a_d = "Depois deste horário, a regra fica pronta de novo para o dia seguinte",
        tenue_t = "Então: roupa", tenue_d = "O perfil de roupa a vestir", laisser = "Não mudar", profil = "Perfil %d",
        endroit_t = "Então: ir para", endroit_d = "O local para onde ir", activite_t = "Então: fazer", activite_d = "A atividade a fazer lá",
        avance_t = "Funções avançadas", avance_d = "Outras condições, decoração, música, fim da regra e senão",
        journee = "O dia todo", jours_t = "Dias", jours_d = "Os dias em que a regra pode agir", tous_jours = "Todos os dias", semaine = "De segunda a sexta", weekend = "Fim de semana",
        jour_noms = { "Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado" },
        essayer_t = "Testar esta regra", essayer_d = "Fecha as opções e faz agora, sejam quais forem as condições", essayer_rien = "—", essayer_alors = "Testar: então", essayer_sinon = "Testar: senão",
        annee_t = "Época do ano", annee_d = "Estações do hemisfério norte. Os meses valem em todo lugar", toute_annee = "O ano todo",
        saisons = { printemps = "Primavera", ete = "Verão", automne = "Outono", hiver = "Inverno" },
        mois_noms = { "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro" },
        pomodoro_t = "Pomodoro", pomodoro_d = "O estado do temporizador Pomodoro do jogo", peu_importe = "Tanto faz", p_travail = "Trabalhando", p_pause = "Em descanso", p_arrete = "Parado",
        musique_si_t = "Música", musique_si_d = "O estado do reprodutor de música do jogo", m_lecture = "Tocando", m_pause = "Pausada",
        decor_t = "Então: decoração", decor_d = "O perfil de decoração do local onde o avatar está", musique_t = "Então: música", musique_d = "O reprodutor de música do jogo", m_suivante = "Próxima faixa",
        sens_t = "Condição", sens_d = "A regra pode agir quando estas condições são verdadeiras ou quando não são", si = "Se for verdade", si_non = "Se não for verdade",
        fin_t = "No fim da regra", fin_d = "Quando a condição deixa de ser verdadeira. O que você mudou não é tocado", fin_rien = "Não fazer nada", fin_avant = "Deixar como estava",
        s_tenue_t = "Senão: roupa", s_tenue_d = "Quando a condição não é verdadeira", s_endroit_t = "Senão: ir para", s_endroit_d = "Quando a condição não é verdadeira", s_activite_t = "Senão: fazer", s_activite_d = "A atividade a fazer lá",
        suppr_t = "Excluir esta regra", suppr_d = "Escolha Sim para excluí-la", oui = "Sim", non = "Não",
        Bedroom = "Quarto", Train = "Trem", Garden = "Jardim", Library = "Biblioteca",
    },
    ja = {
        onglet = "ルール", section = "ルール", regle_t = "ルール", regle_d = "変更するルールを選ぶか、新しく作成します", nom = "ルール %d", nouvelle = "新しいルール", aucune = "ルールなし",
        actif_t = "ルールを有効にする", actif_d = "ルールは条件が変わったときに動作します。その間は自由に別のことができます",
        de_t = "開始", de_d = "ルールが動作する時刻", a_t = "終了", a_d = "この時刻を過ぎると、ルールは翌日に向けて再び待機します",
        tenue_t = "実行：服装", tenue_d = "着用する服装プリセット", laisser = "変更しない", profil = "プリセット %d",
        endroit_t = "実行：移動先", endroit_d = "移動する場所", activite_t = "実行：行動", activite_d = "そこで行うアクティビティ",
        avance_t = "詳細機能", avance_d = "その他の条件、内装、音楽、ルールの終了、それ以外の場合",
        journee = "終日", jours_t = "曜日", jours_d = "ルールが動作できる曜日", tous_jours = "毎日", semaine = "月曜から金曜", weekend = "週末",
        jour_noms = { "日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日" },
        essayer_t = "このルールを試す", essayer_d = "オプションを閉じ、条件に関係なく今すぐ実行します", essayer_rien = "—", essayer_alors = "試す：実行", essayer_sinon = "試す：それ以外",
        annee_t = "時期", annee_d = "季節は北半球のものです。月はどこでも使えます", toute_annee = "一年中",
        saisons = { printemps = "春", ete = "夏", automne = "秋", hiver = "冬" },
        mois_noms = { "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        pomodoro_t = "ポモドーロ", pomodoro_d = "ゲーム内のポモドーロタイマーの状態", peu_importe = "指定なし", p_travail = "作業中", p_pause = "休憩中", p_arrete = "停止中",
        musique_si_t = "音楽", musique_si_d = "ゲーム内の音楽プレイヤーの状態", m_lecture = "再生中", m_pause = "一時停止中",
        decor_t = "実行：内装", decor_d = "アバターがいる場所の内装プリセット", musique_t = "実行：音楽", musique_d = "ゲーム内の音楽プレイヤー", m_suivante = "次の曲",
        sens_t = "条件", sens_d = "これらの条件が真のとき、または真でないときに動作できます", si = "真の場合", si_non = "真でない場合",
        fin_t = "ルールの終了時", fin_d = "条件が真でなくなったとき。自分で変更したものはそのままです", fin_rien = "何もしない", fin_avant = "元に戻す",
        s_tenue_t = "それ以外：服装", s_tenue_d = "条件が真でないとき", s_endroit_t = "それ以外：移動先", s_endroit_d = "条件が真でないとき", s_activite_t = "それ以外：行動", s_activite_d = "そこで行うアクティビティ",
        suppr_t = "このルールを削除", suppr_d = "削除するには「はい」を選びます", oui = "はい", non = "いいえ",
        Bedroom = "寝室", Train = "列車", Garden = "庭", Library = "図書館",
    },
    zh = {
        onglet = "规则", section = "规则", regle_t = "规则", regle_d = "选择要修改的规则，或新建一条", nom = "规则 %d", nouvelle = "新建规则", aucune = "暂无规则",
        actif_t = "启用规则", actif_d = "规则在条件变化时执行。其间你可以自由做别的事",
        de_t = "开始时间", de_d = "规则执行的时间", a_t = "结束时间", a_d = "过了这个时间，规则会为第二天重新就绪",
        tenue_t = "则：服装", tenue_d = "要穿的服装预设", laisser = "不更改", profil = "预设 %d",
        endroit_t = "则：前往", endroit_d = "要前往的地点", activite_t = "则：进行", activite_d = "在那里进行的活动",
        avance_t = "高级功能", avance_d = "其他条件、装饰、音乐、规则结束和否则",
        journee = "全天", jours_t = "日期", jours_d = "规则可以执行的日子", tous_jours = "每天", semaine = "周一至周五", weekend = "周末",
        jour_noms = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" },
        essayer_t = "试用此规则", essayer_d = "关闭选项并立即执行，不管条件如何", essayer_rien = "—", essayer_alors = "试用：则", essayer_sinon = "试用：否则",
        annee_t = "一年中的时间", annee_d = "季节按北半球计算。月份在任何地方都适用", toute_annee = "全年",
        saisons = { printemps = "春季", ete = "夏季", automne = "秋季", hiver = "冬季" },
        mois_noms = { "一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月" },
        pomodoro_t = "番茄钟", pomodoro_d = "游戏内番茄钟的状态", peu_importe = "不限", p_travail = "工作中", p_pause = "休息中", p_arrete = "已停止",
        musique_si_t = "音乐", musique_si_d = "游戏内音乐播放器的状态", m_lecture = "播放中", m_pause = "已暂停",
        decor_t = "则：装饰", decor_d = "角色所在地点的装饰预设", musique_t = "则：音乐", musique_d = "游戏内的音乐播放器", m_suivante = "下一首",
        sens_t = "条件", sens_d = "规则可在这些条件为真或不为真时执行", si = "如果为真", si_non = "如果不为真",
        fin_t = "规则结束时", fin_d = "当条件不再为真时。你自己更改的内容不会被动到", fin_rien = "不做任何事", fin_avant = "恢复原样",
        s_tenue_t = "否则：服装", s_tenue_d = "当条件不为真时", s_endroit_t = "否则：前往", s_endroit_d = "当条件不为真时", s_activite_t = "否则：进行", s_activite_d = "在那里进行的活动",
        suppr_t = "删除此规则", suppr_d = "选择“是”即可删除", oui = "是", non = "否",
        Bedroom = "卧室", Train = "列车", Garden = "花园", Library = "图书馆",
    },
    ko = {
        onglet = "규칙", section = "규칙", regle_t = "규칙", regle_d = "변경할 규칙을 선택하거나 새로 만드세요", nom = "규칙 %d", nouvelle = "새 규칙", aucune = "규칙 없음",
        actif_t = "규칙 사용", actif_d = "규칙은 조건이 바뀔 때 작동합니다. 그 사이에는 자유롭게 다른 일을 할 수 있습니다",
        de_t = "시작", de_d = "규칙이 작동하는 시각", a_t = "종료", a_d = "이 시각이 지나면 규칙은 다음 날을 위해 다시 준비됩니다",
        tenue_t = "실행: 의상", tenue_d = "입을 의상 프리셋", laisser = "변경 안 함", profil = "프리셋 %d",
        endroit_t = "실행: 이동", endroit_d = "이동할 장소", activite_t = "실행: 활동", activite_d = "그곳에서 할 활동",
        avance_t = "고급 기능", avance_d = "다른 조건, 인테리어, 음악, 규칙 종료, 그렇지 않으면",
        journee = "하루 종일", jours_t = "요일", jours_d = "규칙이 작동할 수 있는 요일", tous_jours = "매일", semaine = "월요일부터 금요일", weekend = "주말",
        jour_noms = { "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일" },
        essayer_t = "이 규칙 시험", essayer_d = "옵션을 닫고 조건과 상관없이 바로 실행합니다", essayer_rien = "—", essayer_alors = "시험: 실행", essayer_sinon = "시험: 그렇지 않으면",
        annee_t = "시기", annee_d = "계절은 북반구 기준입니다. 월은 어디서나 쓸 수 있습니다", toute_annee = "일 년 내내",
        saisons = { printemps = "봄", ete = "여름", automne = "가을", hiver = "겨울" },
        mois_noms = { "1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월" },
        pomodoro_t = "뽀모도로", pomodoro_d = "게임 내 뽀모도로 타이머의 상태", peu_importe = "상관없음", p_travail = "작업 중", p_pause = "휴식 중", p_arrete = "정지됨",
        musique_si_t = "음악", musique_si_d = "게임 내 음악 플레이어의 상태", m_lecture = "재생 중", m_pause = "일시 정지",
        decor_t = "실행: 인테리어", decor_d = "아바타가 있는 장소의 인테리어 프리셋", musique_t = "실행: 음악", musique_d = "게임 내 음악 플레이어", m_suivante = "다음 곡",
        sens_t = "조건", sens_d = "이 조건이 참일 때 또는 참이 아닐 때 작동할 수 있습니다", si = "참이면", si_non = "참이 아니면",
        fin_t = "규칙이 끝날 때", fin_d = "조건이 더 이상 참이 아닐 때. 직접 바꾼 것은 건드리지 않습니다", fin_rien = "아무것도 안 함", fin_avant = "원래대로",
        s_tenue_t = "그렇지 않으면: 의상", s_tenue_d = "조건이 참이 아닐 때", s_endroit_t = "그렇지 않으면: 이동", s_endroit_d = "조건이 참이 아닐 때", s_activite_t = "그렇지 않으면: 활동", s_activite_d = "그곳에서 할 활동",
        suppr_t = "이 규칙 삭제", suppr_d = "삭제하려면 예를 선택하세요", oui = "예", non = "아니요",
        Bedroom = "침실", Train = "기차", Garden = "정원", Library = "도서관",
    },
    ru = {
        onglet = "Правила", section = "ПРАВИЛА", regle_t = "Правило", regle_d = "Выберите правило для изменения или создайте новое", nom = "Правило %d", nouvelle = "Новое правило", aucune = "Правил нет",
        actif_t = "Правило включено", actif_d = "Правило срабатывает, когда меняется его условие. В остальное время вы свободны делать что угодно",
        de_t = "С", de_d = "Время, когда срабатывает правило", a_t = "До", a_d = "После этого времени правило снова готово на следующий день",
        tenue_t = "Тогда: одежда", tenue_d = "Какой профиль одежды надеть", laisser = "Не менять", profil = "Профиль %d",
        endroit_t = "Тогда: перейти", endroit_d = "Куда перейти", activite_t = "Тогда: занятие", activite_d = "Чем заняться там",
        avance_t = "Расширенные функции", avance_d = "Другие условия, обстановка, музыка, конец правила и иначе",
        journee = "Весь день", jours_t = "Дни", jours_d = "Дни, когда правило может срабатывать", tous_jours = "Каждый день", semaine = "С понедельника по пятницу", weekend = "Выходные",
        jour_noms = { "Воскресенье", "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота" },
        essayer_t = "Проверить правило", essayer_d = "Закрывает настройки и выполняет сейчас, какими бы ни были условия", essayer_rien = "—", essayer_alors = "Проверить: тогда", essayer_sinon = "Проверить: иначе",
        annee_t = "Время года", annee_d = "Сезоны северного полушария. Месяцы подходят везде", toute_annee = "Весь год",
        saisons = { printemps = "Весна", ete = "Лето", automne = "Осень", hiver = "Зима" },
        mois_noms = { "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь" },
        pomodoro_t = "Помодоро", pomodoro_d = "Состояние таймера Помодоро в игре", peu_importe = "Неважно", p_travail = "Работа", p_pause = "Перерыв", p_arrete = "Остановлен",
        musique_si_t = "Музыка", musique_si_d = "Состояние музыкального плеера в игре", m_lecture = "Играет", m_pause = "На паузе",
        decor_t = "Тогда: обстановка", decor_d = "Профиль обстановки места, где находится аватар", musique_t = "Тогда: музыка", musique_d = "Музыкальный плеер в игре", m_suivante = "Следующий трек",
        sens_t = "Условие", sens_d = "Правило может срабатывать, когда эти условия верны или когда они неверны", si = "Если верно", si_non = "Если неверно",
        fin_t = "В конце правила", fin_d = "Когда условие перестаёт быть верным. То, что вы изменили сами, не трогается", fin_rien = "Ничего не делать", fin_avant = "Вернуть как было",
        s_tenue_t = "Иначе: одежда", s_tenue_d = "Когда условие неверно", s_endroit_t = "Иначе: перейти", s_endroit_d = "Когда условие неверно", s_activite_t = "Иначе: занятие", s_activite_d = "Чем заняться там",
        suppr_t = "Удалить правило", suppr_d = "Выберите Да, чтобы удалить", oui = "Да", non = "Нет",
        Bedroom = "Спальня", Train = "Поезд", Garden = "Сад", Library = "Библиотека",
    },
}
-- The lists: "or" between conditions, steps in "then" and "else".
do
    local LISTES = {
        en = {
            condition_t = "If", condition_d = "Several conditions: one true is enough (or)", condition_nom = "Condition %d", condition_ajout = "Add an \"or\"",
            appli_t = "Application open", appli_d = "An application with an open window", appli_sans_d = "Needs the Real Screen mod to know the open windows",
            retirer_c_t = "Remove this condition", retirer_c_d = "Pick Yes to remove it",
            etape_t = "Then", etape_d = "Several steps: done in order", etape_nom = "Step %d", etape_ajout = "Add a step",
            attente_t = "Wait first", attente_d = "How long to wait after the step before", sans_attente = "No wait", minutes = "%d min",
            retirer_e_t = "Remove this step", retirer_e_d = "Pick Yes to remove it",
            s_etape_t = "Else", s_etape_d = "When the condition is not true. Several steps: done in order", aucune_etape = "Nothing",
            s_decor_t = "Else: room preset", s_musique_t = "Else: music",
        },
        fr = {
            condition_t = "Si", condition_d = "Plusieurs conditions : une seule vraie suffit (ou)", condition_nom = "Condition %d", condition_ajout = "Ajouter un « ou »",
            appli_t = "Application ouverte", appli_d = "Une application avec une fenêtre ouverte", appli_sans_d = "Demande le mod Real Screen pour connaître les fenêtres ouvertes",
            retirer_c_t = "Retirer cette condition", retirer_c_d = "Choisissez Oui pour la retirer",
            etape_t = "Alors", etape_d = "Plusieurs étapes : faites dans l'ordre", etape_nom = "Étape %d", etape_ajout = "Ajouter une étape",
            attente_t = "Attendre d'abord", attente_d = "Le temps d'attente après l'étape d'avant", sans_attente = "Sans attendre", minutes = "%d min",
            retirer_e_t = "Retirer cette étape", retirer_e_d = "Choisissez Oui pour la retirer",
            s_etape_t = "Sinon", s_etape_d = "Quand la condition n'est pas vraie. Plusieurs étapes : faites dans l'ordre", aucune_etape = "Rien",
            s_decor_t = "Sinon : décor", s_musique_t = "Sinon : musique",
        },
        it = {
            condition_t = "Se", condition_d = "Più condizioni: ne basta una vera (o)", condition_nom = "Condizione %d", condition_ajout = "Aggiungi un «o»",
            appli_t = "Applicazione aperta", appli_d = "Un'applicazione con una finestra aperta", appli_sans_d = "Richiede la mod Real Screen per conoscere le finestre aperte",
            retirer_c_t = "Rimuovi questa condizione", retirer_c_d = "Scegli Sì per rimuoverla",
            etape_t = "Allora", etape_d = "Più passaggi: eseguiti in ordine", etape_nom = "Passaggio %d", etape_ajout = "Aggiungi un passaggio",
            attente_t = "Prima attendi", attente_d = "Quanto attendere dopo il passaggio precedente", sans_attente = "Senza attesa", minutes = "%d min",
            retirer_e_t = "Rimuovi questo passaggio", retirer_e_d = "Scegli Sì per rimuoverlo",
            s_etape_t = "Altrimenti", s_etape_d = "Quando la condizione non è vera. Più passaggi: eseguiti in ordine", aucune_etape = "Niente",
            s_decor_t = "Altrimenti: arredamento", s_musique_t = "Altrimenti: musica",
        },
        de = {
            condition_t = "Wenn", condition_d = "Mehrere Bedingungen: Eine wahre genügt (oder)", condition_nom = "Bedingung %d", condition_ajout = "„Oder“ hinzufügen",
            appli_t = "Anwendung geöffnet", appli_d = "Eine Anwendung mit einem offenen Fenster", appli_sans_d = "Braucht die Mod Real Screen, um die offenen Fenster zu kennen",
            retirer_c_t = "Diese Bedingung entfernen", retirer_c_d = "Wähle Ja, um sie zu entfernen",
            etape_t = "Dann", etape_d = "Mehrere Schritte: der Reihe nach", etape_nom = "Schritt %d", etape_ajout = "Schritt hinzufügen",
            attente_t = "Zuerst warten", attente_d = "Wie lange nach dem vorherigen Schritt gewartet wird", sans_attente = "Ohne Warten", minutes = "%d Min.",
            retirer_e_t = "Diesen Schritt entfernen", retirer_e_d = "Wähle Ja, um ihn zu entfernen",
            s_etape_t = "Sonst", s_etape_d = "Wenn die Bedingung nicht wahr ist. Mehrere Schritte: der Reihe nach", aucune_etape = "Nichts",
            s_decor_t = "Sonst: Einrichtung", s_musique_t = "Sonst: Musik",
        },
        es = {
            condition_t = "Si", condition_d = "Varias condiciones: basta con que una sea cierta (o)", condition_nom = "Condición %d", condition_ajout = "Añadir un «o»",
            appli_t = "Aplicación abierta", appli_d = "Una aplicación con una ventana abierta", appli_sans_d = "Necesita el mod Real Screen para conocer las ventanas abiertas",
            retirer_c_t = "Quitar esta condición", retirer_c_d = "Elige Sí para quitarla",
            etape_t = "Entonces", etape_d = "Varios pasos: se hacen en orden", etape_nom = "Paso %d", etape_ajout = "Añadir un paso",
            attente_t = "Esperar antes", attente_d = "Cuánto esperar después del paso anterior", sans_attente = "Sin esperar", minutes = "%d min",
            retirer_e_t = "Quitar este paso", retirer_e_d = "Elige Sí para quitarlo",
            s_etape_t = "Si no", s_etape_d = "Cuando la condición no es cierta. Varios pasos: se hacen en orden", aucune_etape = "Nada",
            s_decor_t = "Si no: decoración", s_musique_t = "Si no: música",
        },
        pt = {
            condition_t = "Se", condition_d = "Várias condições: basta uma ser verdadeira (ou)", condition_nom = "Condição %d", condition_ajout = "Adicionar um “ou”",
            appli_t = "Aplicativo aberto", appli_d = "Um aplicativo com uma janela aberta", appli_sans_d = "Precisa do mod Real Screen para conhecer as janelas abertas",
            retirer_c_t = "Remover esta condição", retirer_c_d = "Escolha Sim para removê-la",
            etape_t = "Então", etape_d = "Várias etapas: feitas em ordem", etape_nom = "Etapa %d", etape_ajout = "Adicionar uma etapa",
            attente_t = "Esperar antes", attente_d = "Quanto esperar depois da etapa anterior", sans_attente = "Sem esperar", minutes = "%d min",
            retirer_e_t = "Remover esta etapa", retirer_e_d = "Escolha Sim para removê-la",
            s_etape_t = "Senão", s_etape_d = "Quando a condição não é verdadeira. Várias etapas: feitas em ordem", aucune_etape = "Nada",
            s_decor_t = "Senão: decoração", s_musique_t = "Senão: música",
        },
        ja = {
            condition_t = "条件", condition_d = "複数の条件：どれか1つが真なら十分です（または）", condition_nom = "条件 %d", condition_ajout = "「または」を追加",
            appli_t = "開いているアプリ", appli_d = "ウィンドウが開いているアプリ", appli_sans_d = "開いているウィンドウを知るには Real Screen MOD が必要です",
            retirer_c_t = "この条件を削除", retirer_c_d = "削除するには「はい」を選びます",
            etape_t = "実行", etape_d = "複数のステップ：順番に行います", etape_nom = "ステップ %d", etape_ajout = "ステップを追加",
            attente_t = "先に待つ", attente_d = "前のステップのあとに待つ時間", sans_attente = "待たない", minutes = "%d 分",
            retirer_e_t = "このステップを削除", retirer_e_d = "削除するには「はい」を選びます",
            s_etape_t = "それ以外", s_etape_d = "条件が真でないとき。複数のステップ：順番に行います", aucune_etape = "なし",
            s_decor_t = "それ以外：内装", s_musique_t = "それ以外：音楽",
        },
        zh = {
            condition_t = "如果", condition_d = "多个条件：只要一个为真即可（或）", condition_nom = "条件 %d", condition_ajout = "添加“或”",
            appli_t = "已打开的应用", appli_d = "有打开窗口的应用", appli_sans_d = "需要 Real Screen 模组才能知道已打开的窗口",
            retirer_c_t = "移除此条件", retirer_c_d = "选择“是”即可移除",
            etape_t = "则", etape_d = "多个步骤：按顺序进行", etape_nom = "步骤 %d", etape_ajout = "添加步骤",
            attente_t = "先等待", attente_d = "上一步之后等待多久", sans_attente = "不等待", minutes = "%d 分钟",
            retirer_e_t = "移除此步骤", retirer_e_d = "选择“是”即可移除",
            s_etape_t = "否则", s_etape_d = "当条件不为真时。多个步骤：按顺序进行", aucune_etape = "无",
            s_decor_t = "否则：装饰", s_musique_t = "否则：音乐",
        },
        ko = {
            condition_t = "조건", condition_d = "여러 조건: 하나만 참이면 됩니다 (또는)", condition_nom = "조건 %d", condition_ajout = "'또는' 추가",
            appli_t = "열려 있는 앱", appli_d = "창이 열려 있는 앱", appli_sans_d = "열린 창을 알려면 Real Screen 모드가 필요합니다",
            retirer_c_t = "이 조건 제거", retirer_c_d = "제거하려면 예를 선택하세요",
            etape_t = "실행", etape_d = "여러 단계: 순서대로 실행합니다", etape_nom = "단계 %d", etape_ajout = "단계 추가",
            attente_t = "먼저 대기", attente_d = "이전 단계 후 기다릴 시간", sans_attente = "대기 없음", minutes = "%d분",
            retirer_e_t = "이 단계 제거", retirer_e_d = "제거하려면 예를 선택하세요",
            s_etape_t = "그렇지 않으면", s_etape_d = "조건이 참이 아닐 때. 여러 단계: 순서대로 실행합니다", aucune_etape = "없음",
            s_decor_t = "그렇지 않으면: 인테리어", s_musique_t = "그렇지 않으면: 음악",
        },
        ru = {
            condition_t = "Если", condition_d = "Несколько условий: достаточно одного верного (или)", condition_nom = "Условие %d", condition_ajout = "Добавить «или»",
            appli_t = "Открытое приложение", appli_d = "Приложение с открытым окном", appli_sans_d = "Нужен мод Real Screen, чтобы знать открытые окна",
            retirer_c_t = "Убрать это условие", retirer_c_d = "Выберите Да, чтобы убрать",
            etape_t = "Тогда", etape_d = "Несколько шагов: выполняются по порядку", etape_nom = "Шаг %d", etape_ajout = "Добавить шаг",
            attente_t = "Сначала подождать", attente_d = "Сколько ждать после предыдущего шага", sans_attente = "Без ожидания", minutes = "%d мин",
            retirer_e_t = "Убрать этот шаг", retirer_e_d = "Выберите Да, чтобы убрать",
            s_etape_t = "Иначе", s_etape_d = "Когда условие неверно. Несколько шагов: выполняются по порядку", aucune_etape = "Ничего",
            s_decor_t = "Иначе: обстановка", s_musique_t = "Иначе: музыка",
        },
    }
    for code, textes in pairs(LISTES) do
        for cle, valeur in pairs(textes) do TEXTES[code][cle] = valeur end
    end
end
-- Where an application is: in front on its screen, or behind, and which screen.
do
    local PLANS = {
        en = { plan_t = "Application is", plan_d = "In front on its screen, or behind other windows or minimized", plan_ouverte = "Open", plan_devant = "In front", plan_derriere = "In the background", ecran_t = "On screen", ecran_d = "The screen of that application's window", ecran_tous = "Any screen", ecran_nom = "Screen %s (%s)", appli_sans_d = "The file avatar_fenetres.dll is missing or blocked by an antivirus" },
        fr = { plan_t = "L'application est", plan_d = "Devant sur son écran, ou derrière d'autres fenêtres, ou réduite", plan_ouverte = "Ouverte", plan_devant = "Au premier plan", plan_derriere = "En arrière-plan", ecran_t = "Sur l'écran", ecran_d = "L'écran de la fenêtre de cette application", ecran_tous = "N'importe quel écran", ecran_nom = "Écran %s (%s)", appli_sans_d = "Le fichier avatar_fenetres.dll manque ou est bloqué par un antivirus" },
        it = { plan_t = "L'applicazione è", plan_d = "Davanti sul suo schermo, oppure dietro altre finestre o ridotta", plan_ouverte = "Aperta", plan_devant = "In primo piano", plan_derriere = "In secondo piano", ecran_t = "Sullo schermo", ecran_d = "Lo schermo della finestra di questa applicazione", ecran_tous = "Qualsiasi schermo", ecran_nom = "Schermo %s (%s)", appli_sans_d = "Il file avatar_fenetres.dll manca o è bloccato da un antivirus" },
        de = { plan_t = "Die Anwendung ist", plan_d = "Vorne auf ihrem Bildschirm, oder hinter anderen Fenstern oder minimiert", plan_ouverte = "Geöffnet", plan_devant = "Im Vordergrund", plan_derriere = "Im Hintergrund", ecran_t = "Auf Bildschirm", ecran_d = "Der Bildschirm des Fensters dieser Anwendung", ecran_tous = "Beliebiger Bildschirm", ecran_nom = "Bildschirm %s (%s)", appli_sans_d = "Die Datei avatar_fenetres.dll fehlt oder wird von einem Virenschutz blockiert" },
        es = { plan_t = "La aplicación está", plan_d = "Delante en su pantalla, o detrás de otras ventanas o minimizada", plan_ouverte = "Abierta", plan_devant = "En primer plano", plan_derriere = "En segundo plano", ecran_t = "En la pantalla", ecran_d = "La pantalla de la ventana de esta aplicación", ecran_tous = "Cualquier pantalla", ecran_nom = "Pantalla %s (%s)", appli_sans_d = "Falta el archivo avatar_fenetres.dll o lo bloquea un antivirus" },
        pt = { plan_t = "O aplicativo está", plan_d = "Na frente em sua tela, ou atrás de outras janelas ou minimizado", plan_ouverte = "Aberto", plan_devant = "Em primeiro plano", plan_derriere = "Em segundo plano", ecran_t = "Na tela", ecran_d = "A tela da janela deste aplicativo", ecran_tous = "Qualquer tela", ecran_nom = "Tela %s (%s)", appli_sans_d = "O arquivo avatar_fenetres.dll está faltando ou foi bloqueado por um antivírus" },
        ja = { plan_t = "アプリの状態", plan_d = "その画面で最前面、または他のウィンドウの後ろや最小化", plan_ouverte = "開いている", plan_devant = "最前面", plan_derriere = "背面", ecran_t = "画面", ecran_d = "このアプリのウィンドウがある画面", ecran_tous = "すべての画面", ecran_nom = "画面 %s (%s)", appli_sans_d = "avatar_fenetres.dll がないか、ウイルス対策ソフトにブロックされています" },
        zh = { plan_t = "应用状态", plan_d = "在其屏幕的最前面，或在其他窗口后面或已最小化", plan_ouverte = "已打开", plan_devant = "在前台", plan_derriere = "在后台", ecran_t = "屏幕", ecran_d = "此应用窗口所在的屏幕", ecran_tous = "任意屏幕", ecran_nom = "屏幕 %s (%s)", appli_sans_d = "文件 avatar_fenetres.dll 缺失或被杀毒软件阻止" },
        ko = { plan_t = "앱 상태", plan_d = "해당 화면의 맨 앞, 또는 다른 창 뒤나 최소화", plan_ouverte = "열림", plan_devant = "앞에 있음", plan_derriere = "뒤에 있음", ecran_t = "화면", ecran_d = "이 앱의 창이 있는 화면", ecran_tous = "모든 화면", ecran_nom = "화면 %s (%s)", appli_sans_d = "avatar_fenetres.dll 파일이 없거나 백신 프로그램이 차단했습니다" },
        ru = { plan_t = "Приложение", plan_d = "Впереди на своём экране, либо за другими окнами или свёрнуто", plan_ouverte = "Открыто", plan_devant = "На переднем плане", plan_derriere = "На заднем плане", ecran_t = "На экране", ecran_d = "Экран окна этого приложения", ecran_tous = "Любой экран", ecran_nom = "Экран %s (%s)", appli_sans_d = "Файл avatar_fenetres.dll отсутствует или заблокирован антивирусом" },
    }
    for code, textes in pairs(PLANS) do
        for cle, valeur in pairs(textes) do TEXTES[code][cle] = valeur end
    end
end
-- A language missing a text falls back on English, one text at a time.
for code, table_langue in pairs(TEXTES) do
    if code ~= "en" then setmetatable(table_langue, { __index = TEXTES.en }) end
end

local MENU = { cree = false, lignes = {}, langue = nil, texte = TEXTES.en, choisie = 1, cree_a = 0, panneau = nil, prochain_hud = 0 }

local function langue_du_jeu()
    local ok, langue = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):GetCurrentLanguage():ToString()
    end)
    return (ok and langue) or "en"
end

local function choisir_langue()
    MENU.langue = langue_du_jeu()
    MENU.texte = TEXTES[MENU.langue:sub(1, 2):lower()] or TEXTES.en
end

-- A name from the game's own text table, in its language.
local NOMS_JEU = {}  -- emptied when the language changes
local function texte_jeu(cle, secours)
    if NOMS_JEU[cle] then return NOMS_JEU[cle] end
    local ok, v = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):TextFromStringTable(FName(TABLE_TEXTES), cle):ToString()
    end)
    if ok and v and v ~= "" and not v:find("<MISSING", 1, true) then
        NOMS_JEU[cle] = v
        return v
    end
    return secours
end

-- ---------------------------------------------------------------- the tab, made by the game's own tab bar
local CHAMP_ACTIF = "isActive_6_AAA2810D4B0D667D1CA69287A7F3214D"
local CHAMP_NOM = "DisplayName_3_441B5CC848A78063CDAC3D9B88444E36"
local CHAMP_PAGE = "TabToOpen_10_F12151F6483D437F1A32A3B047523C2B"
local CHAMP_ICONE = "Icontexture_14_B0CA026F439CF4DDE6ACECB63EF862EA"
local ICONE_ONGLET = "/Game/UI/HUD/Icons/T_UI_Clock.T_UI_Clock"

local function nouveau_widget(classe_moteur, outer)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. classe_moteur), outer)
end

local function copier_case(de, vers)
    vers:SetPadding(de.Padding)
    vers:SetSize(de.Size)
    vers:SetHorizontalAlignment(de.HorizontalAlignment)
    vers:SetVerticalAlignment(de.VerticalAlignment)
end

local function regler_textes(ligne, titre, description)
    ligne.item.Title = FText(titre)
    ligne.item.Description = FText(description)
    ligne.item:Update()
end

-- One row built like the game's own: SizeBox > Border > HorizontalBox > (texts, spacer, dropdown).
local function creer_ligne(p, modele, boite)
    local bib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local joueur = p:GetOwningPlayer()
    local sb = nouveau_widget("SizeBox", p)
    sb:SetHeightOverride(modele.taille.HeightOverride)
    local bord = nouveau_widget("Border", p)
    bord:SetBrush(modele.bord.Background)
    bord:SetPadding(modele.bord.Padding)
    bord:SetBrushColor(modele.bord.BrushColor)
    local rang = nouveau_widget("HorizontalBox", p)
    local item = bib:Create(p, modele.classe_item, joueur)
    local espace = nouveau_widget("Spacer", p)
    local liste = bib:Create(p, modele.classe_liste, joueur)
    sb:SetContent(bord)
    bord:SetContent(rang)
    copier_case(modele.item.Slot, rang:AddChild(item))
    copier_case(modele.espace.Slot, rang:AddChild(espace))
    copier_case(modele.liste.Slot, rang:AddChild(liste))
    copier_case(modele.taille.Slot, boite:AddChild(sb))
    return { boite = sb, item = item, liste = liste, options = {}, valeur = nil }
end

local function poser_textes()
    local t, l = MENU.texte, MENU.lignes
    MENU.titre:SetText(FText(t.section))
    regler_textes(l.regle, t.regle_t, t.regle_d)
    regler_textes(l.actif, t.actif_t, t.actif_d)
    regler_textes(l.de, t.de_t, t.de_d)
    regler_textes(l.a, t.a_t, t.a_d)
    regler_textes(l.tenue, t.tenue_t, t.tenue_d)
    regler_textes(l.endroit, t.endroit_t, t.endroit_d)
    regler_textes(l.activite, t.activite_t, t.activite_d)
    regler_textes(l.condition, t.condition_t, t.condition_d)
    regler_textes(l.appli, t.appli_t, t.appli_d)
    regler_textes(l.appli_plan, t.plan_t, t.plan_d)
    regler_textes(l.appli_ecran, t.ecran_t, t.ecran_d)
    regler_textes(l.retirer_c, t.retirer_c_t, t.retirer_c_d)
    regler_textes(l.etape, t.etape_t, t.etape_d)
    regler_textes(l.attente, t.attente_t, t.attente_d)
    regler_textes(l.retirer_e, t.retirer_e_t, t.retirer_e_d)
    regler_textes(l.s_etape, t.s_etape_t, t.s_etape_d)
    regler_textes(l.s_attente, t.attente_t, t.attente_d)
    regler_textes(l.s_decor, t.s_decor_t, t.decor_d)
    regler_textes(l.s_musique, t.s_musique_t, t.musique_d)
    regler_textes(l.s_retirer, t.retirer_e_t, t.retirer_e_d)
    regler_textes(l.jours, t.jours_t, t.jours_d)
    regler_textes(l.essayer, t.essayer_t, t.essayer_d)
    regler_textes(l.annee, t.annee_t, t.annee_d)
    regler_textes(l.pomodoro, t.pomodoro_t, t.pomodoro_d)
    regler_textes(l.musique_si, t.musique_si_t, t.musique_si_d)
    regler_textes(l.decor, t.decor_t, t.decor_d)
    regler_textes(l.musique, t.musique_t, t.musique_d)
    regler_textes(l.avance, t.avance_t, t.avance_d)
    regler_textes(l.sens, t.sens_t, t.sens_d)
    regler_textes(l.fin, t.fin_t, t.fin_d)
    regler_textes(l.s_tenue, t.s_tenue_t, t.s_tenue_d)
    regler_textes(l.s_endroit, t.s_endroit_t, t.s_endroit_d)
    regler_textes(l.s_activite, t.s_activite_t, t.s_activite_d)
    regler_textes(l.suppr, t.suppr_t, t.suppr_d)
end

local function creer_onglet(p)
    choisir_langue()
    local t = MENU.texte
    local sw = p.WidgetSwitcher
    local modele_liste = p.WB_TimeFormatSelector
    local rang = modele_liste:GetParent()
    local bord = rang:GetParent()
    local taille = bord:GetParent()
    local boite = taille:GetParent()
    local modele = {
        taille = taille, bord = bord, liste = modele_liste,
        item = rang:GetChildAt(0), espace = rang:GetChildAt(1),
        classe_item = rang:GetChildAt(0):GetClass(), classe_liste = modele_liste:GetClass(),
    }
    local titre_modele = boite:GetChildAt(0)

    -- The page: a scrolling list in the switcher, next to the game's pages. No row of the game is touched.
    local page = nouveau_widget("VerticalBox", p)
    local defile = nouveau_widget("ScrollBox", p)
    pcall(function()
        local liste_jeu = p.WBP_BaseScrollBox.ScrollBox_Items
        defile.WidgetBarStyle = liste_jeu.WidgetBarStyle
        defile:SetScrollbarThickness(liste_jeu.ScrollbarThickness)
    end)
    local section = nouveau_widget("VerticalBox", p)
    local titre = nouveau_widget("TextBlock", p)
    titre:SetFont(titre_modele.Font)
    titre:SetColorAndOpacity(titre_modele.ColorAndOpacity)
    MENU.titre = titre
    copier_case(titre_modele.Slot, section:AddChild(titre))
    defile:AddChild(section)
    local case = page:AddChild(defile)
    case:SetPadding(boite.Slot.Padding)
    case:SetSize({ SizeRule = 1, Value = 1.0 })
    sw:AddChild(page)
    MENU.page = page

    local l = MENU.lignes
    for _, nom_ligne in ipairs({ "regle", "actif", "condition", "de", "a", "jours", "appli", "appli_plan", "appli_ecran", "annee", "pomodoro", "musique_si", "retirer_c", "etape", "attente", "tenue", "endroit", "activite", "decor", "musique", "retirer_e", "essayer", "avance", "sens", "fin", "s_etape", "s_attente", "s_tenue", "s_endroit", "s_activite", "s_decor", "s_musique", "s_retirer", "suppr" }) do
        l[nom_ligne] = creer_ligne(p, modele, section)
    end
    poser_textes()

    -- The tab: one more entry in the data the game's tab bar builds itself from, so its button, its look and its click are the game's.
    local barre = p.UI_TabBar
    local data = barre["Tab buttons data"]
    local icone = StaticFindObject(ICONE_ONGLET)
    if not valide(icone) then icone = data[1][CHAMP_ICONE] end
    MENU.index_page = sw:GetChildIndex(page)
    local rangee = #data + 1
    data[rangee] = {
        [CHAMP_ACTIF] = false,
        [CHAMP_NOM] = FText(t.onglet),
        [CHAMP_PAGE] = MENU.index_page,
        [CHAMP_ICONE] = icone,
    }
    MENU.rangee_onglet = rangee
    barre:RefreshData()
    MENU.cree = true
    MENU.cree_a = os.clock()
    MENU.panneau = p
    MENU.donnees_panneau = p:GetAddress()
    journal("onglet cree : page " .. tostring(MENU.index_page) .. ", " .. tostring(barre.TabBarContent:GetChildrenCount()) .. " boutons")
end

-- ---------------------------------------------------------------- the rule editor
local DELAI_AVANT_PREMIER_CHOIX = 1.5

local function regler_options(ligne, options, selection)
    local combo = ligne.liste.ComboBox
    local identiques = #options == #ligne.options and combo:GetOptionCount() == #options
    if identiques then
        for i, o in ipairs(options) do
            if ligne.options[i] ~= o then identiques = false end
        end
    end
    if not identiques then
        combo:ClearOptions()
        for _, o in ipairs(options) do combo:AddOption(o) end
        ligne.options = options
    end
    if not identiques or ligne.valeur ~= selection then
        combo:SetSelectedOption(selection)
        ligne.valeur = selection
    end
end

-- Anything different from what was last shown is what the player has just picked.
local function lu(ligne)
    if #ligne.options == 0 then return nil end
    local valeur = ligne.liste.ComboBox:GetSelectedOption():ToString()
    if valeur ~= ligne.valeur and valeur ~= "" then
        if os.clock() - MENU.cree_a < DELAI_AVANT_PREMIER_CHOIX then
            ligne.valeur = nil
            return nil
        end
        return valeur
    end
    return nil
end

-- "8:30" or "8" into minutes since midnight. nil means no time set.
local function minutes_de(texte)
    if not rempli(texte) then return nil end
    local h, m = tostring(texte):match("^(%d+):(%d+)$")
    if h then return tonumber(h) * 60 + tonumber(m) end
    local seule = tonumber(texte)
    return seule and seule * 60 or nil
end

local function libelle_heure(texte)
    local total = minutes_de(texte) or 0
    return string.format("%02d:%02d", total // 60, total % 60)
end

local function heures(avec_journee)
    local liste = {}
    if avec_journee then liste[1] = MENU.texte.journee end
    for h = 0, 23 do
        for m = 0, 45, 15 do liste[#liste + 1] = string.format("%02d:%02d", h, m) end
    end
    return liste
end

local function vers_stocke(libelle)
    local h, m = libelle:match("^(%d+):(%d+)$")
    return h and (tonumber(h) .. ":" .. m) or ""
end

-- Two labels must never be the same text: the label is what comes back from the dropdown.
local function ajouter_unique(liste, actions, texte, valeur)
    local final, n = texte, 1
    while actions[final] ~= nil do
        n = n + 1
        final = texte .. " " .. n
    end
    liste[#liste + 1] = final
    actions[final] = valeur
    return final
end

-- A fixed list: { { text, stored value }, ... }. Returns the labels, what each label means, and the one showing.
local function liste_fixe(paires, valeur)
    local labels, actions, choisi = {}, {}, nil
    for _, p in ipairs(paires) do
        local texte = ajouter_unique(labels, actions, p[1], p[2])
        if (valeur or "") == p[2] then choisi = texte end
    end
    return labels, actions, choisi or labels[1]
end

-- One dropdown tied to one stored field: picks are stored, then the row shows the stored value.
local function ligne_fixe(ligne, objet, champ, paires)
    local labels, actions, _ = liste_fixe(paires, objet[champ])
    local v = lu(ligne)
    local change = false
    if v and actions[v] ~= nil and actions[v] ~= objet[champ] then
        objet[champ] = actions[v]
        change = true
    end
    local _, _, choisi = liste_fixe(paires, objet[champ])
    regler_options(ligne, labels, choisi)
    return change
end

local function paires_jours()
    local t = MENU.texte
    local p = { { t.tous_jours, "tous" }, { t.semaine, "semaine" }, { t.weekend, "weekend" } }
    -- Monday first, Sunday last. The stored number is Lua's: 1 is Sunday.
    for _, n in ipairs({ 2, 3, 4, 5, 6, 7, 1 }) do p[#p + 1] = { t.jour_noms[n], tostring(n) } end
    return p
end

local function paires_annee()
    local t = MENU.texte
    local p = { { t.toute_annee, "" } }
    for _, s in ipairs({ "printemps", "ete", "automne", "hiver" }) do p[#p + 1] = { t.saisons[s], s } end
    for i = 1, 12 do p[#p + 1] = { t.mois_noms[i], "m" .. i } end
    return p
end

local function paires_profils(nombre)
    local t = MENU.texte
    local p = { { t.laisser, "" } }
    for i = 1, nombre do p[#p + 1] = { string.format(t.profil, i), tostring(i) } end
    return p
end

local function paires_endroits()
    local t = MENU.texte
    local p = { { t.laisser, "" } }
    for _, e in ipairs(ENDROITS) do
        if possede(e.dlc) then p[#p + 1] = { (t[e.carte] or e.carte) .. " : " .. texte_jeu(e.cle, e.id), e.id } end
    end
    return p
end

local function paires_activites(endroit)
    local p = {}
    for _, a in ipairs(ACTIVITES[endroit] or {}) do
        p[#p + 1] = { texte_jeu("Activity_" .. a[2], a[1]), endroit .. "_" .. a[1] }
    end
    return p
end

local function paires_attente()
    local t = MENU.texte
    local p = { { t.sans_attente, "0" } }
    for _, m in ipairs({ 1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120 }) do p[#p + 1] = { string.format(t.minutes, m), tostring(m) } end
    return p
end

local function paires_applis(actuelle)
    local p = { { MENU.texte.peu_importe, "" } }
    local vues = {}
    for _, nom in ipairs(APPLIS.liste) do
        vues[nom] = true
        p[#p + 1] = { nom, nom }
    end
    -- Closed for now: it stays chosen, and comes back when the program does.
    if rempli(actuelle) and not vues[actuelle] then p[#p + 1] = { actuelle, actuelle } end
    return p
end

local function paires_ecrans(actuel)
    local t = MENU.texte
    local p = { { t.ecran_tous, "" } }
    local vu = false
    for _, e in ipairs(APPLIS.ecrans) do
        p[#p + 1] = { string.format(t.ecran_nom, e.numero, e.taille), e.numero }
        if e.numero == actuel then vu = true end
    end
    -- A screen switched off for now stays chosen.
    if rempli(actuel) and not vu then p[#p + 1] = { string.format(t.ecran_nom, actuel, "?"), actuel } end
    return p
end

local function regle_avancee(r)
    if r == nil then return false end
    if r.inverse == "1" or r.fin == "avant" or #r.sinon > 0 then return true end
    for _, c in ipairs(r.conditions) do
        if rempli(c.annee) or rempli(c.pomodoro) or rempli(c.musique) then return true end
    end
    for _, e in ipairs(r.alors) do
        if rempli(e.decor) or rempli(e.musique) then return true end
    end
    return false
end

-- Filled in below, where the actions live.
local essayer_regle, annuler_regle = nil, nil

local function montrer(ligne, oui)
    ligne.boite:SetVisibility(oui and 4 or 1)  -- 4 shown, 1 collapsed
end

-- The dropdown that picks one entry of a list, or adds one. Returns the index to edit, and whether the list changed.
local function ligne_liste(ligne, liste, index, format_nom, texte_ajout, texte_vide, creer)
    local labels, actions = {}, {}
    local choisi = nil
    for i = 1, #liste do
        local texte = ajouter_unique(labels, actions, string.format(format_nom, i), i)
        if i == index then choisi = texte end
    end
    -- With an empty list, something else must be showing: picking the entry already shown would not be seen as a choice.
    if #liste == 0 then choisi = ajouter_unique(labels, actions, texte_vide, "vide") end
    ajouter_unique(labels, actions, texte_ajout, "ajout")
    local change = false
    local v = lu(ligne)
    if v and actions[v] == "ajout" then
        liste[#liste + 1] = creer()
        index = #liste
        change = true
        ligne.valeur = nil
    elseif v and type(actions[v]) == "number" then
        index = actions[v]
    end
    if change or (index ~= nil and liste[index] == nil and #liste > 0) then
        -- The entries changed: the labels are built again.
        if liste[index] == nil then index = #liste end
        labels, actions = {}, {}
        for i = 1, #liste do
            local texte = ajouter_unique(labels, actions, string.format(format_nom, i), i)
            if i == index then choisi = texte end
        end
        ajouter_unique(labels, actions, texte_ajout, "ajout")
    end
    if #liste > 0 and liste[index] then choisi = string.format(format_nom, index) end
    regler_options(ligne, labels, choisi or labels[1])
    return index, change
end

-- A "remove this" row: picking Yes is an order, and the row goes back to No.
local function ligne_retirer(ligne)
    local t = MENU.texte
    local v = lu(ligne)
    if v == t.oui then ligne.valeur = nil end
    regler_options(ligne, { t.non, t.oui }, t.non)
    return v == t.oui
end

-- The rows of one list of steps, for "then" or for "else".
local function suivre_etapes(l, r, liste, cle_index, n, visible, t, peut_etre_vide)
    montrer(l[n.etape], visible)
    if not visible then
        for _, nom in ipairs({ n.attente, n.tenue, n.endroit, n.activite, n.decor, n.musique, n.retirer }) do montrer(l[nom], false) end
        return false
    end
    local change = false
    local index, ajoute = ligne_liste(l[n.etape], liste, MENU[cle_index], t.etape_nom, t.etape_ajout, t.aucune_etape, nouvelle_etape)
    MENU[cle_index] = index
    if ajoute then change = true end
    local e = liste[index]
    montrer(l[n.attente], e ~= nil and index > 1)
    montrer(l[n.tenue], e ~= nil)
    montrer(l[n.endroit], e ~= nil)
    montrer(l[n.decor], e ~= nil and MENU.avance)
    montrer(l[n.musique], e ~= nil and MENU.avance)
    montrer(l[n.retirer], e ~= nil and (peut_etre_vide or #liste > 1))
    if not e then
        montrer(l[n.activite], false)
        return change
    end
    if index > 1 and ligne_fixe(l[n.attente], e, "attente", paires_attente()) then change = true end
    if ligne_fixe(l[n.tenue], e, "profil", paires_profils(NOMBRE_PROFILS)) then change = true end
    if ligne_fixe(l[n.endroit], e, "endroit", paires_endroits()) then
        change = true
        local liste_a = ACTIVITES[e.endroit]
        e.activite = liste_a and (e.endroit .. "_" .. liste_a[1][1]) or ""
    end
    local activites = rempli(e.endroit) and paires_activites(e.endroit) or {}
    montrer(l[n.activite], #activites > 0)
    if #activites > 0 and ligne_fixe(l[n.activite], e, "activite", activites) then change = true end
    if MENU.avance then
        if ligne_fixe(l[n.decor], e, "decor", paires_profils(NOMBRE_DECORS)) then change = true end
        if ligne_fixe(l[n.musique], e, "musique", { { t.laisser, "" }, { t.m_lecture, "lecture" }, { t.m_pause, "pause" }, { t.m_suivante, "suivante" } }) then change = true end
    end
    if ligne_retirer(l[n.retirer]) then
        table.remove(liste, index)
        MENU[cle_index] = math.max(1, math.min(index, #liste))
        l[n.etape].valeur = nil
        change = true
    end
    return change
end

local NOMS_ALORS = { etape = "etape", attente = "attente", tenue = "tenue", endroit = "endroit", activite = "activite", decor = "decor", musique = "musique", retirer = "retirer_e" }
local NOMS_SINON = { etape = "s_etape", attente = "s_attente", tenue = "s_tenue", endroit = "s_endroit", activite = "s_activite", decor = "s_decor", musique = "s_musique", retirer = "s_retirer" }

local function suivre_page()
    local l = MENU.lignes
    local t = MENU.texte
    local change = false

    -- Which rule.
    local avant = MENU.choisie
    local index, ajoute = ligne_liste(l.regle, REGLES, MENU.choisie, t.nom, t.nouvelle, t.aucune, nouvelle_regle)
    MENU.choisie = index
    if ajoute then change = true end
    local r = REGLES[MENU.choisie]
    if MENU.choisie ~= avant or MENU.regle_vue ~= r then
        MENU.regle_vue = r
        MENU.cond_choisie, MENU.etape_choisie, MENU.s_etape_choisie = 1, 1, 1
        MENU.avance = regle_avancee(r)
        for _, nom in ipairs({ "condition", "etape", "s_etape" }) do l[nom].valeur = nil end
    end

    local avec = r ~= nil
    for _, nom in ipairs({ "actif", "condition", "de", "jours", "appli", "essayer", "avance", "suppr" }) do montrer(l[nom], avec) end
    if not avec then
        for _, nom in ipairs({ "a", "appli_plan", "appli_ecran", "annee", "pomodoro", "musique_si", "retirer_c", "sens", "fin" }) do montrer(l[nom], false) end
        suivre_etapes(l, nil, {}, "etape_choisie", NOMS_ALORS, false, t, false)
        suivre_etapes(l, nil, {}, "s_etape_choisie", NOMS_SINON, false, t, true)
        return
    end

    if ligne_fixe(l.actif, r, "actif", { { t.oui, "1" }, { t.non, "0" } }) then change = true end

    -- The conditions: one true is enough.
    local ci, c_ajout = ligne_liste(l.condition, r.conditions, MENU.cond_choisie, t.condition_nom, t.condition_ajout, t.aucune_etape, nouvelle_condition)
    MENU.cond_choisie = ci
    if c_ajout then change = true end
    local c = r.conditions[ci]
    local v = lu(l.de)
    if v then
        c.de = vers_stocke(v)
        if rempli(c.de) and not rempli(c.a) then c.a = c.de end
        change = true
    end
    regler_options(l.de, heures(true), rempli(c.de) and libelle_heure(c.de) or t.journee)
    montrer(l.a, rempli(c.de))
    v = lu(l.a)
    if v then c.a = vers_stocke(v); change = true end
    regler_options(l.a, heures(false), libelle_heure(rempli(c.a) and c.a or c.de))
    if ligne_fixe(l.jours, c, "jours", paires_jours()) then change = true end
    if ligne_fixe(l.appli, c, "appli", paires_applis(c.appli)) then change = true end
    -- Where that application must be. Nothing to choose until an application is picked.
    local avec_appli = rempli(c.appli)
    montrer(l.appli_plan, avec_appli)
    montrer(l.appli_ecran, avec_appli)
    if avec_appli then
        if ligne_fixe(l.appli_plan, c, "plan", { { t.plan_ouverte, "" }, { t.plan_devant, "devant" }, { t.plan_derriere, "derriere" } }) then change = true end
        if ligne_fixe(l.appli_ecran, c, "ecran", paires_ecrans(c.ecran)) then change = true end
    end
    -- Without the DLL there is no list of windows: the row says why it stays empty.
    local sans = not APPLIS.connues
    if sans ~= MENU.appli_sans or MENU.appli_langue ~= MENU.langue then
        MENU.appli_sans, MENU.appli_langue = sans, MENU.langue
        regler_textes(l.appli, t.appli_t, sans and t.appli_sans_d or t.appli_d)
    end

    -- The advanced rows.
    v = lu(l.avance)
    if v then MENU.avance = v == t.oui end
    regler_options(l.avance, { t.non, t.oui }, MENU.avance and t.oui or t.non)
    for _, nom in ipairs({ "annee", "pomodoro", "musique_si", "sens", "fin" }) do montrer(l[nom], MENU.avance) end
    if MENU.avance then
        if ligne_fixe(l.annee, c, "annee", paires_annee()) then change = true end
        if ligne_fixe(l.pomodoro, c, "pomodoro", { { t.peu_importe, "" }, { t.p_travail, "travail" }, { t.p_pause, "pause" }, { t.p_arrete, "arrete" } }) then change = true end
        if ligne_fixe(l.musique_si, c, "musique", { { t.peu_importe, "" }, { t.m_lecture, "lecture" }, { t.m_pause, "pause" } }) then change = true end
        if ligne_fixe(l.sens, r, "inverse", { { t.si, "0" }, { t.si_non, "1" } }) then change = true end
        if ligne_fixe(l.fin, r, "fin", { { t.fin_rien, "rien" }, { t.fin_avant, "avant" } }) then change = true end
    end
    montrer(l.retirer_c, #r.conditions > 1)
    if #r.conditions > 1 and ligne_retirer(l.retirer_c) then
        table.remove(r.conditions, ci)
        MENU.cond_choisie = math.max(1, math.min(ci, #r.conditions))
        l.condition.valeur = nil
        change = true
    end

    -- Then, and else.
    if suivre_etapes(l, r, r.alors, "etape_choisie", NOMS_ALORS, true, t, false) then change = true end
    if suivre_etapes(l, r, r.sinon, "s_etape_choisie", NOMS_SINON, MENU.avance, t, true) then change = true end

    -- The "try" list always falls back to its first entry: picking something is an order, not a setting.
    local essais = { t.essayer_rien, t.essayer_alors }
    if #r.sinon > 0 then essais[3] = t.essayer_sinon end
    local essai_demande = lu(l.essayer)
    if essai_demande then l.essayer.valeur = nil end
    regler_options(l.essayer, essais, t.essayer_rien)

    if ligne_retirer(l.suppr) then
        annuler_regle(r)
        table.remove(REGLES, MENU.choisie)
        MENU.choisie = math.max(1, math.min(MENU.choisie, #REGLES))
        l.regle.valeur = nil
        MENU.regle_vue = false
        ecrire_regles()
        journal("regle supprimee : " .. #REGLES .. " restante(s)")
        return
    end
    if change then
        annuler_regle(r)
        r.vrai_avant = nil  -- a rule just edited is looked at afresh as soon as the options close
        ecrire_regles()
        journal("regles enregistrees : " .. #REGLES)
    end
    if essai_demande == t.essayer_alors or essai_demande == t.essayer_sinon then
        essayer_regle(r, essai_demande == t.essayer_sinon)
    end
end

local function options_ouvertes(h)
    local p = h.UI_SettingsPanel
    local parent = p:GetParent()
    return valide(parent) and h.WidgetSwitcher:GetActiveWidgetIndex() == h.WidgetSwitcher:GetChildIndex(parent)
end

local function surveiller_menu()
    local t = os.clock()
    if t >= MENU.prochain_hud then
        MENU.prochain_hud = t + 1
        MENU.hud = hud()
        local p = MENU.hud and MENU.hud.UI_SettingsPanel or nil
        if valide(p) and (not MENU.cree or MENU.donnees_panneau ~= p:GetAddress()) then
            MENU.cree = false
            MENU.lignes = {}
            creer_onglet(p)
        end
    end
    local p = MENU.panneau
    MENU.page_ouverte = false
    if not MENU.cree or not valide(p) or not valide(MENU.hud) then return end
    if not options_ouvertes(MENU.hud) then return end
    -- The language can change while the options are open.
    if langue_du_jeu() ~= MENU.langue then
        choisir_langue()
        NOMS_JEU = {}
        poser_textes()
        local data = p.UI_TabBar["Tab buttons data"]
        data[MENU.rangee_onglet][CHAMP_NOM] = FText(MENU.texte.onglet)
        -- The buttons are built again from this data: it must say which tab is the active one, or two end up underlined.
        local page_active = p.WidgetSwitcher:GetActiveWidgetIndex()
        for i = 1, #data do
            data[i][CHAMP_ACTIF] = data[i][CHAMP_PAGE] == page_active
        end
        p.UI_TabBar:RefreshData()
        p.UI_TabBar["Refesh Tab Selection"](p.UI_TabBar, page_active)
        journal("langue : " .. MENU.langue)
    end
    if p.WidgetSwitcher:GetActiveWidgetIndex() == MENU.index_page then
        MENU.page_ouverte = true
        suivre_page()
    end
end

-- ---------------------------------------------------------------- when a rule is true
local ESSAI = {}  -- set only through the test bridge, which needs dev.txt

-- The real date, or the test bridge's.
local function date_actuelle()
    local d = os.date("*t")
    local minutes = d.hour * 60 + d.min
    if PONT then
        if ESSAI.heure then minutes = ESSAI.heure * 60 end
        if ESSAI.minutes then minutes = ESSAI.minutes end
        if ESSAI.jour then d.wday = ESSAI.jour end
        if ESSAI.mois then d.month = ESSAI.mois end
    end
    return minutes, d.wday, d.month
end

local function heure_vraie(c, maintenant)
    local de = minutes_de(c.de)
    if not de then return true end  -- all day
    local a = minutes_de(c.a) or de
    if de == a then return maintenant == de end
    if de < a then return maintenant >= de and maintenant < a end
    return maintenant >= de or maintenant < a  -- across midnight
end

local function jour_vrai(c, jour)
    if not rempli(c.jours) or c.jours == "tous" then return true end
    if c.jours == "semaine" then return jour >= 2 and jour <= 6 end
    if c.jours == "weekend" then return jour == 1 or jour == 7 end
    return tonumber(c.jours) == jour
end

local SAISONS = { printemps = { 3, 4, 5 }, ete = { 6, 7, 8 }, automne = { 9, 10, 11 }, hiver = { 12, 1, 2 } }

local function annee_vraie(c, mois)
    if not rempli(c.annee) then return true end
    local n = c.annee:match("^m(%d+)$")
    if n then return tonumber(n) == mois end
    for _, m in ipairs(SAISONS[c.annee] or {}) do
        if m == mois then return true end
    end
    return false
end

-- Segment types: 0 work, 1 short break, 2 long break. A Pomodoro that cannot be read is in no state at all.
local function etat_pomodoro()
    local ok, etat = pcall(function()
        local p = hud().UI_PomodoroV2.WBP_PomodoroV2
        if p.State == 0 then return "arrete" end
        local sortie, reussi = {}, {}
        p:GetSegmentAtIndex(p.CurrentSegment, sortie, reussi)
        local segment = sortie["AsWBP Pomodoro 2 Single Section"]
        if segment and segment:IsValid() then return segment.Type == 0 and "travail" or "pause" end
        return nil
    end)
    return ok and etat or nil
end

local function musique_joue()
    local ok, v = pcall(function() return hud().UI_MusicPlayer.IsPlaying end)
    return ok and v == true
end

local function condition_simple_vraie(c, maintenant, jour, mois)
    if not (heure_vraie(c, maintenant) and jour_vrai(c, jour) and annee_vraie(c, mois)) then return false end
    if rempli(c.pomodoro) and etat_pomodoro() ~= c.pomodoro then return false end
    if rempli(c.musique) and (c.musique == "lecture") ~= musique_joue() then return false end
    if rempli(c.appli) then
        local trouvee = false
        for _, f in ipairs(APPLIS.ouvertes[c.appli] or {}) do
            local bon_ecran = not rempli(c.ecran) or f.ecran == c.ecran
            -- In the background: behind another window on its screen, or minimized.
            local bon_plan = not rempli(c.plan) or (c.plan == "devant") == (f.etat == "devant")
            if bon_ecran and bon_plan then trouvee = true end
        end
        if not trouvee then return false end
    end
    return true
end

-- nil: cannot tell for now (no list of windows). Nothing is decided on that.
local function regle_vraie(r)
    local maintenant, jour, mois = date_actuelle()
    local vrai = false
    for _, c in ipairs(r.conditions) do
        if rempli(c.appli) and not APPLIS.connues then return nil end
        if condition_simple_vraie(c, maintenant, jour, mois) then vrai = true end
    end
    if r.inverse == "1" then return not vrai end
    return vrai
end

local function regle_veut_applis()
    for _, r in ipairs(REGLES) do
        if r.actif == "1" then
            for _, c in ipairs(r.conditions) do
                if rempli(c.appli) then return true end
            end
        end
    end
    return false
end

-- The list of open windows comes from avatar_fenetres.dll, on request. A rule that needs nothing costs nothing.
-- Only program names, screens and whether a window is in front. Never a title.
local function demander_applis()
    local t = os.clock()
    if t < APPLIS.prochain then return end
    if not (regle_veut_applis() or MENU.page_ouverte or (PONT and ESSAI.applis)) then return end
    APPLIS.prochain = t + 2
    if PONT and ESSAI.applis then
        -- "name" or "name:screen:state"
        APPLIS.connues = true
        APPLIS.ouvertes, APPLIS.liste = {}, {}
        for _, entree in ipairs(ESSAI.applis) do
            local nom, ecran, etat = entree:match("^([^:]+):?([^:]*):?([^:]*)$")
            if not APPLIS.ouvertes[nom] then
                APPLIS.ouvertes[nom] = {}
                APPLIS.liste[#APPLIS.liste + 1] = nom
            end
            table.insert(APPLIS.ouvertes[nom], { ecran = ecran ~= "" and ecran or "1", etat = etat ~= "" and etat or "devant" })
        end
        return
    end
    if not APPLIS.module then
        APPLIS.connues = false
        return
    end
    local demande = DOSSIER .. "demande_fenetres.txt"
    -- The request is still there from last time: the DLL is not answering.
    local encore = io.open(demande, "r")
    if encore then
        encore:close()
        APPLIS.sans_reponse = (APPLIS.sans_reponse or 0) + 1
        if APPLIS.sans_reponse >= 3 then APPLIS.connues = false end
        return
    end
    APPLIS.sans_reponse = 0
    local f = io.open(DOSSIER .. "fenetres.txt", "r")
    if f then
        local ouvertes, liste, ecrans = {}, {}, {}
        for ligne in f:lines() do
            local numero, taille = ligne:match("^E\t([^\t]*)\t(.*)$")
            if numero then ecrans[#ecrans + 1] = { numero = numero, taille = taille } end
            local exe, ecran, etat = ligne:match("^A\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if exe and exe ~= "" then
                if not ouvertes[exe] then
                    ouvertes[exe] = {}
                    -- The game itself still counts for who is in front of what, but it is not something to pick.
                    if not exe:find("^SpiritCity") then liste[#liste + 1] = exe end
                end
                table.insert(ouvertes[exe], { ecran = ecran, etat = etat })
            end
        end
        f:close()
        table.sort(liste, function(a, b) return a:lower() < b:lower() end)
        table.sort(ecrans, function(a, b) return (tonumber(a.numero) or 0) < (tonumber(b.numero) or 0) end)
        APPLIS.ouvertes, APPLIS.liste, APPLIS.ecrans, APPLIS.connues = ouvertes, liste, ecrans, true
    end
    local d = io.open(demande, "w")
    if d then d:close() end
end

local function endroit_du_rang(rang)
    for _, e in ipairs(ENDROITS) do
        if rang:sub(1, #e.id + 1) == e.id .. "_" then return e.id end
    end
    return nil
end

-- A safety net: two rules, or a rule and its own effect, could keep undoing each other.
local ACTIONS_RECENTES = {}
local LIMITE_ACTIONS, FENETRE_ACTIONS = 10, 60
local function trop_d_actions()
    local t, gardees = os.clock(), {}
    for _, quand in ipairs(ACTIONS_RECENTES) do
        if t - quand < FENETRE_ACTIONS then gardees[#gardees + 1] = quand end
    end
    ACTIONS_RECENTES = gardees
    return #gardees >= LIMITE_ACTIONS
end

-- Steps waiting for their time. What is due is grouped into one action, carried out over several frames.
local FILE = {}
local ACTION = nil

local function peut_agir()
    local h, lieu, cartes = hud(), gestion_lieu(), gestion_cartes()
    if not (valide(h) and valide(lieu) and valide(cartes)) then return false end
    if lieu.isDoingAvatarCustomization or lieu.isDoingRoomCustomization then return false end
    if cartes.MapTraversalInProgress then return false end
    if options_ouvertes(h) then return false end
    return true
end

annuler_regle = function(r)
    local gardees = {}
    for _, entree in ipairs(FILE) do
        if entree.regle ~= r then gardees[#gardees + 1] = entree end
    end
    FILE = gardees
end

-- A list of steps goes into the file, each one after the waits before it.
local function programmer(r, etapes, essai)
    local quand = os.clock()
    for i, e in ipairs(etapes) do
        if i > 1 then
            local minutes = tonumber(e.attente) or 0
            if essai then
                quand = quand + (minutes > 0 and 3 or 0)  -- a try does not make the player wait
            else
                quand = quand + minutes * ((PONT and ESSAI.secondes_par_minute) or 60)
            end
        end
        FILE[#FILE + 1] = {
            quand = quand, regle = r, essai = essai,
            profil = e.profil, rang = rempli(e.endroit) and e.activite or "", decor = e.decor, musique = e.musique,
        }
    end
end

local function effacer_suivi(r)
    r.en_cours = "0"
    r.avant_profil, r.avant_rang, r.avant_decor, r.avant_musique = "", "", "", ""
    r.pose_profil, r.pose_rang, r.pose_decor, r.pose_musique = "", "", "", ""
end

local function evaluer_regles()
    if ACTION then return end
    -- A rule acts only at the moment its condition changes: it never fights the player afterwards.
    local montantes, descendantes = {}, {}
    local coupee = false
    for _, r in ipairs(REGLES) do
        if r.actif ~= "1" then
            r.vrai_avant = nil
            if r.en_cours == "1" then
                annuler_regle(r)
                effacer_suivi(r)
                coupee = true
            end
        else
            local vrai = regle_vraie(r)
            if vrai == true and r.vrai_avant ~= true then
                montantes[#montantes + 1] = r
            elseif vrai == false and r.vrai_avant ~= false then
                descendantes[#descendantes + 1] = r
            end
        end
    end
    if #montantes == 0 and #descendantes == 0 then
        if coupee then ecrire_regles() end
        return
    end
    if not peut_agir() then return end  -- not now: looked at again in a moment

    local etat = {
        profil = tostring(gestion_tenue()["Current Preset ID"]),
        rang = gestion_lieu().CurrentActivityData.RowName:ToString(),
        decor = tostring(hud().REF_RoomCustomizationManager["Current Preset ID"]),
        musique = musique_joue() and "lecture" or "pause",
    }
    -- What starts goes before what ends, and rules higher in the list go first.
    for _, r in ipairs(montantes) do
        annuler_regle(r)
        if r.en_cours ~= "1" then
            r.avant_profil, r.avant_rang, r.avant_decor, r.avant_musique = etat.profil, etat.rang, etat.decor, etat.musique
            r.pose_profil, r.pose_rang, r.pose_decor, r.pose_musique = "", "", "", ""
        end
        r.en_cours = "1"
        programmer(r, r.alors, false)
        r.vrai_avant = true
        journal("regle vraie : " .. #r.alors .. " etape(s)")
    end
    for _, r in ipairs(descendantes) do
        local apres_relance = r.vrai_avant == nil
        annuler_regle(r)
        programmer(r, r.sinon, false)
        if r.en_cours == "1" and r.fin == "avant" then
            -- Only what the rule set and the player has not changed since. After a restart no activity is running yet: that is not the player's doing.
            local retour = { quand = os.clock(), regle = r, retour = true, profil = "", rang = "", decor = "", musique = "" }
            if rempli(r.pose_profil) and r.pose_profil == etat.profil then retour.profil = r.avant_profil end
            if rempli(r.pose_rang) and (r.pose_rang == etat.rang or apres_relance) and r.avant_rang ~= "None" then retour.rang = r.avant_rang end
            if rempli(r.pose_decor) and r.pose_decor == etat.decor then retour.decor = r.avant_decor end
            if rempli(r.pose_musique) and r.pose_musique == etat.musique then retour.musique = r.avant_musique end
            FILE[#FILE + 1] = retour
        end
        effacer_suivi(r)
        r.vrai_avant = false
        journal("regle fausse : fin " .. tostring(r.fin) .. ", sinon " .. #r.sinon .. " etape(s)")
    end
    ecrire_regles()
end

-- What is due becomes one action. Between rules the first in the file wins each kind of change; inside one rule, a later step wins over an earlier one.
local function lancer_ce_qui_est_du()
    if ACTION or #FILE == 0 then return end
    local t = os.clock()
    local du = false
    for _, entree in ipairs(FILE) do
        if entree.quand <= t then du = true end
    end
    if not du or not peut_agir() then return end
    if trop_d_actions() then
        if not MENU.limite_signalee then
            MENU.limite_signalee = true
            journal("trop d'actions en une minute : les regles attendent")
        end
        return
    end
    MENU.limite_signalee = false
    local cible, par_regle, gardees = {}, {}, {}
    local maj = false
    for _, entree in ipairs(FILE) do
        if entree.quand <= t then
            for _, champ in ipairs({ "profil", "rang", "decor", "musique" }) do
                -- "Put things back" only fills what nothing else decided: else goes first, even in the same rule.
                if rempli(entree[champ]) and (cible[champ] == nil or (par_regle[champ] == entree.regle and not entree.retour)) then
                    cible[champ] = entree[champ]
                    par_regle[champ] = entree.regle
                    -- What the rule has really put in place, for "put things back".
                    if not entree.essai and not entree.retour then
                        local valeur = entree[champ]
                        if champ ~= "musique" or valeur ~= "suivante" then
                            entree.regle["pose_" .. champ] = valeur
                            maj = true
                        end
                    end
                end
            end
        else
            gardees[#gardees + 1] = entree
        end
    end
    FILE = gardees
    if maj then ecrire_regles() end
    if cible.profil or cible.rang or cible.decor or cible.musique then
        ACTIONS_RECENTES[#ACTIONS_RECENTES + 1] = t
        ACTION = {
            etape = "carte", profil = tonumber(cible.profil), rang = cible.rang, endroit = cible.rang and endroit_du_rang(cible.rang) or "",
            decor = tonumber(cible.decor), musique = cible.musique, depuis = t,
        }
        journal("action : profil " .. tostring(cible.profil) .. ", activite " .. tostring(cible.rang) .. ", decor " .. tostring(cible.decor) .. ", musique " .. tostring(cible.musique))
    end
end

essayer_regle = function(r, sinon)
    if ACTION then return end
    -- The test itself is not a change of the condition: the rule carries on from what is true now.
    if r.actif == "1" then
        local vrai = regle_vraie(r)
        if vrai ~= nil then r.vrai_avant = vrai end
    end
    programmer(r, sinon and r.sinon or r.alors, true)
    journal("essai de la regle : " .. (sinon and "sinon" or "alors"))
    MENU.hud:EvSimulateSettingsPress()
end

local function aller_activite(rang)
    local lieu = gestion_lieu()
    local dt = StaticFindObject(TABLE_ACTIVITES)
    lieu:GoToActivity({ DataTable = dt, RowName = FName(rang) })
    journal("activite " .. rang .. " -> " .. tostring(lieu.CurrentActivity))
end

local function fin_action(raison)
    journal("fin de l'action : " .. raison)
    ACTION = nil
end

local function bouton_profil(n)
    local h = hud()
    local editeur = h and h.UI_AvatarCustomization
    if not valide(editeur) then return nil end
    return editeur["UI_SinglePresetButton_" .. n]
end

local EDITEURS_DECOR = { Bedroom = "UI_RoomCustomization", Train = "UI_RoomCustomization_Train", Garden = "UI_RoomCustomization_Garden", Library = "UI_RoomCustomization_Library" }

local function bouton_decor(n)
    local h = hud()
    local editeur = h and h[EDITEURS_DECOR[gestion_cartes().CurrentMap:ToString()] or ""]
    if not valide(editeur) then return nil end
    return editeur["UI_SinglePresetButton_" .. n]
end

-- See the top of this file: what may load a file is never called directly from Lua.
local function appel_par_minuterie(objet, fonction)
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):K2_SetTimer(objet, fonction, 0.01, false, false, 0.0, 0.0)
end

local function regler_musique(voulu)
    local lecteur = hud().UI_MusicPlayer
    if voulu == "suivante" then
        appel_par_minuterie(lecteur, "EvSimulateNext")
    elseif (voulu == "lecture") ~= musique_joue() then
        appel_par_minuterie(lecteur, "EvSimulatePlayPause")
    end
end

local function pas_action()
    local a = ACTION
    local t = os.clock()
    if t - a.depuis > 90 then fin_action("trop long"); return end
    if a.attendre_jusqua and t < a.attendre_jusqua then return end
    if a.etape == "carte" then
        local e = ENDROIT_PAR_ID[a.endroit]
        if a.rang and e then
            if not possede(e.dlc) then fin_action("contenu non possede : " .. e.id); return end
            local cartes = gestion_cartes()
            if cartes.CurrentMap:ToString() ~= e.carte then
                journal("carte " .. e.carte)
                GARDES = {}
                cartes:SwitchMap(FName(e.carte))
                a.etape = "attente_carte"
                a.attendre_jusqua = t + 2
                return
            end
        end
        a.etape = "decor"
    elseif a.etape == "attente_carte" then
        local cartes = gestion_cartes()
        if not valide(cartes) or cartes.MapTraversalInProgress then return end
        local lieu = gestion_lieu()
        if not valide(lieu) then return end
        a.etape = "decor"
        a.attendre_jusqua = t + 3  -- the new map's avatars settle
    elseif a.etape == "decor" then
        a.etape = "profil"
        if a.decor then
            local gestion = hud().REF_RoomCustomizationManager
            if valide(gestion) and gestion["Current Preset ID"] ~= a.decor then
                local b = bouton_decor(a.decor)
                if valide(b) then
                    appel_par_minuterie(b.WBP_BaseButton_Simple, "EvSimulatePress")
                    a.etape = "attente_decor"
                    a.decor_depuis = t
                else
                    journal("pas de bouton de decor ici")
                end
            end
        end
    elseif a.etape == "attente_decor" then
        local gestion = hud().REF_RoomCustomizationManager
        if valide(gestion) and gestion["Current Preset ID"] == a.decor then
            a.etape = "profil"
        elseif t - a.decor_depuis > 10 then
            journal("le decor n'a pas change")
            a.etape = "profil"
        end
    elseif a.etape == "profil" then
        local m = gestion_tenue()
        if a.profil and valide(m) and m["Current Preset ID"] ~= a.profil then
            local b = bouton_profil(a.profil)
            if not valide(b) then fin_action("pas de bouton de profil"); return end
            appel_par_minuterie(b.WBP_BaseButton_Simple, "EvSimulatePress")
            a.etape = "attente_profil"
            a.profil_depuis = t
            return
        end
        a.change_profil = false
        a.etape = "activite"
    elseif a.etape == "attente_profil" then
        local m = gestion_tenue()
        if valide(m) and m["Current Preset ID"] == a.profil then
            a.change_profil = true
            a.etape = "activite"
        elseif t - a.profil_depuis > 10 then
            fin_action("le profil n'a pas change")
        end
    elseif a.etape == "activite" then
        local lieu = gestion_lieu()
        local rang = a.rang
        if not rang and a.change_profil then
            rang = lieu.CurrentActivityData.RowName:ToString()
            if rang == "None" then rang = nil end
        end
        if rang then
            aller_activite(rang)
            -- The game itself refuses what is not unlocked yet: nothing is forced.
            if lieu.CurrentActivityData.RowName:ToString() ~= rang then journal("activite refusee par le jeu : " .. rang) end
        elseif a.change_profil then
            -- No activity running: the editor's normal exit puts the camera back. No Lua on the stack here either.
            appel_par_minuterie(lieu, "ExitAvatarCustomization")
        end
        if a.musique then regler_musique(a.musique) end
        fin_action("faite")
    end
end

-- ---------------------------------------------------------------- start
local function traiter_pont()
    if not PONT then return end
    local f = io.open(PONT .. "ordre.lua", "r")
    if not f then return end
    local code = f:read("a")
    f:close()
    os.remove(PONT .. "ordre.lua")
    local sortie = {}
    local env = setmetatable({
        sortie = sortie, dire = function(x) sortie[#sortie + 1] = tostring(x) end,
        REGLES = REGLES, MENU = MENU, journal = journal, gestion_lieu = gestion_lieu, gestion_tenue = gestion_tenue, gestion_cartes = gestion_cartes,
        hud = hud, action = function() return ACTION end, regle_vraie = regle_vraie, ecrire_regles = ecrire_regles, ESSAI = ESSAI, APPLIS = APPLIS, file_longueur = function() return #FILE end, nouvelle_regle = nouvelle_regle, nouvelle_condition = nouvelle_condition, nouvelle_etape = nouvelle_etape, annuler_regle = annuler_regle,
    }, { __index = _G })
    local fn, err = load(code, "ordre", "t", env)
    if not fn then
        sortie[1] = "ERREUR chargement " .. tostring(err)
    else
        local ok, e = pcall(fn)
        if not ok then sortie[#sortie + 1] = "ERREUR " .. tostring(e) end
    end
    local tmp = PONT .. "resultats.tmp"
    local s = io.open(tmp, "w")
    if s then
        s:write(table.concat(sortie, "\n"), "\nFIN\n")
        s:close()
        os.remove(PONT .. "resultats.txt")
        os.rename(tmp, PONT .. "resultats.txt")
    end
end

lire_regles()
journal("mod charge, " .. #REGLES .. " regle(s)")
do
    local ok, err = package.loadlib(DOSSIER .. "avatar_fenetres.dll", "*")
    APPLIS.module = ok and true or false
    journal("liste des fenetres : " .. (APPLIS.module and "prete" or ("absente : " .. tostring(err))))
end

local TICK = "/Game/Core_Sessions/Core/BP_CameraPawn.BP_CameraPawn_C:ReceiveTick"
local prochain_menu, prochaine_regle, prochain_pont, prochain_pas, ACCROCHE = 0, 3, 0, 0, false

local function a_chaque_image()
    local t = os.clock()
    if PONT and t >= prochain_pont then
        prochain_pont = t + 0.25
        traiter_pont()
    end
    if t >= prochain_menu then
        prochain_menu = t + 0.15
        local ok, err = pcall(surveiller_menu)
        if not ok then
            prochain_menu = t + 5
            journal("ERREUR menu " .. tostring(err))
        end
    end
    if ACTION then
        if t >= prochain_pas then
            prochain_pas = t + 0.05
            local ok, err = pcall(pas_action)
            if not ok then
                journal("ERREUR action " .. tostring(err))
                ACTION = nil
            end
        end
    elseif t >= prochaine_regle then
        prochaine_regle = t + 2
        local ok, err = pcall(function()
            demander_applis()
            evaluer_regles()
            lancer_ce_qui_est_du()
        end)
        if not ok then journal("ERREUR regles " .. tostring(err)) end
    end
end

-- The camera pawn's class is only loaded once the world starts.
RegisterBeginPlayPostHook(function()
    if ACCROCHE then return end
    local ok = pcall(RegisterHook, TICK, a_chaque_image)
    if ok then
        ACCROCHE = true
        journal("accroche a chaque image posee")
    end
end)
