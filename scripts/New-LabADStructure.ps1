<#
.SYNOPSIS
    Complète l'arborescence Site_Paris, crée les groupes de service et les utilisateurs
    à partir d'un CSV, puis range les postes dans l'OU de leur service.

.DESCRIPTION
    Structure attendue dans le domaine (créée si elle manque) :
        OU Site_Paris
          ├── OU Admin            (comptes d'administration, non gérés par ce script)
          ├── OU <Service>        (Comptabilite, Developpement, Direction, Marketing, RH)
          │     ├── OU users
          │     └── OU computers
          └── OU Groupes          (un groupe de sécurité global GRP_<Service> par service)

    1. Pour chaque ligne de utilisateurs.csv (Prenom, Nom, Service, Fonction), le script crée
       un compte prenom.nom (sans accents, en minuscules) dans <Service>\users et l'ajoute
       au groupe GRP_<Service>. Le mot de passe initial est demandé à l'exécution et doit
       être changé à la première connexion.
    2. Pour chaque ligne de ordinateurs.csv (Nom, Service), le script déplace le compte
       ordinateur du conteneur par défaut vers <Service>\computers, pour que les GPO
       ordinateur puissent le cibler.

    Le script est idempotent : un objet déjà présent ou déjà à sa place est signalé et
    ignoré. Il accepte -WhatIf pour simuler sans rien modifier.

.PARAMETER CsvUtilisateurs
    Chemin du CSV des utilisateurs. Par défaut : utilisateurs.csv à côté du script.

.PARAMETER CsvOrdinateurs
    Chemin du CSV des postes. Par défaut : ordinateurs.csv à côté du script.

.PARAMETER Site
    Nom de l'OU racine de l'entreprise. Par défaut : Site_Paris.

.PARAMETER LogPath
    Chemin du journal d'exécution. Par défaut : un fichier horodaté à côté du script.

.EXAMPLE
    .\New-LabADStructure.ps1 -WhatIf
    Simule toutes les opérations sans rien modifier.

.EXAMPLE
    .\New-LabADStructure.ps1
    Exécute réellement les créations et les déplacements.

.NOTES
    Auteur    : Richard Lamah
    Prérequis : module ActiveDirectory (RSAT), droits d'administrateur du domaine.
    Cible     : Windows Server 2019, Windows PowerShell 5.1.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CsvUtilisateurs = (Join-Path $PSScriptRoot 'utilisateurs.csv'),
    [string]$CsvOrdinateurs = (Join-Path $PSScriptRoot 'ordinateurs.csv'),
    [string]$Site = 'Site_Paris',
    [string]$LogPath = (Join-Path $PSScriptRoot ("creation-ad-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
)

Import-Module ActiveDirectory -ErrorAction Stop

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'IGNORE', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; IGNORE = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $LogPath -Value $ligne -Encoding UTF8 -WhatIf:$false
}

function Remove-Accents {
    # "Hélène Condé" -> "Helene Conde" : décompose chaque caractère accentué
    # puis supprime les signes diacritiques.
    param([string]$Texte)
    $decompose = $Texte.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $decompose.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-Identifiant {
    # Construit un sAMAccountName unique de la forme prenom.nom (20 caractères maximum).
    param([string]$Prenom, [string]$Nom)
    $base = (Remove-Accents "$Prenom.$Nom").ToLower() -replace "[^a-z0-9.\-]", ''
    if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }
    $candidat = $base
    $i = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$candidat'" -ErrorAction SilentlyContinue) {
        $suffixe = "$i"
        $candidat = $base.Substring(0, [Math]::Min($base.Length, 20 - $suffixe.Length)) + $suffixe
        $i++
    }
    return $candidat
}

function New-OUSiAbsente {
    # Crée l'OU si elle n'existe pas et renvoie son DistinguishedName dans tous les cas.
    param([string]$Nom, [string]$Parent)
    $dn = "OU=$Nom,$Parent"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Log "OU déjà présente : $dn" 'IGNORE'
    }
    elseif ($PSCmdlet.ShouldProcess($dn, 'Créer l''OU')) {
        New-ADOrganizationalUnit -Name $Nom -Path $Parent -ProtectedFromAccidentalDeletion $true
        Write-Log "OU créée : $dn" 'OK'
    }
    return $dn
}

function Import-CsvVerifie {
    param([string]$Chemin, [string[]]$Colonnes)
    if (-not (Test-Path $Chemin)) { throw "Fichier CSV introuvable : $Chemin" }
    $lignes = @(Import-Csv -Path $Chemin -Encoding UTF8)
    if ($lignes.Count -eq 0) { throw "Fichier CSV vide : $Chemin" }
    $manquantes = $Colonnes | Where-Object { $_ -notin $lignes[0].PSObject.Properties.Name }
    if ($manquantes) { throw "Colonnes absentes de ${Chemin} : $($manquantes -join ', ')" }
    return $lignes
}

# ---------------------------------------------------------------------------
# Contrôles préalables
# ---------------------------------------------------------------------------

$utilisateurs = Import-CsvVerifie -Chemin $CsvUtilisateurs -Colonnes 'Prenom', 'Nom', 'Service', 'Fonction'
$ordinateurs = @()
if (Test-Path $CsvOrdinateurs) {
    $ordinateurs = Import-CsvVerifie -Chemin $CsvOrdinateurs -Colonnes 'Nom', 'Service'
}

$domaine = Get-ADDomain
$suffixeUPN = $domaine.DNSRoot                                   # ex. ecole-gn.gn
$ouSite = "OU=$Site,$($domaine.DistinguishedName)"               # ex. OU=Site_Paris,DC=ecole-gn,DC=gn
$services = @($utilisateurs.Service) + @($ordinateurs.Service) | Where-Object { $_ } | Sort-Object -Unique

Write-Log "Domaine $suffixeUPN, OU racine $ouSite"
Write-Log "$($utilisateurs.Count) utilisateurs, $($ordinateurs.Count) postes, services : $($services -join ', ')"

# Le mot de passe initial n'est demandé qu'au moment de créer le premier compte :
# une relance où tout existe déjà, ou une simulation -WhatIf, ne le demande pas.
$motDePasse = $null

# ---------------------------------------------------------------------------
# 1. Arborescence : Site_Paris, Groupes, et <Service>\users + <Service>\computers
# ---------------------------------------------------------------------------

$ouSite = New-OUSiAbsente -Nom $Site -Parent $domaine.DistinguishedName
$ouGroupes = New-OUSiAbsente -Nom 'Groupes' -Parent $ouSite

$ouUsers = @{}
$ouComputers = @{}
foreach ($service in $services) {
    $ouService = New-OUSiAbsente -Nom $service -Parent $ouSite
    $ouUsers[$service] = New-OUSiAbsente -Nom 'users' -Parent $ouService
    $ouComputers[$service] = New-OUSiAbsente -Nom 'computers' -Parent $ouService
}

# ---------------------------------------------------------------------------
# 2. Groupes de sécurité, un par service
# ---------------------------------------------------------------------------

foreach ($service in $services) {
    $nomGroupe = "GRP_$service"
    if (Get-ADGroup -Filter "Name -eq '$nomGroupe'" -ErrorAction SilentlyContinue) {
        Write-Log "Groupe déjà présent : $nomGroupe" 'IGNORE'
    }
    elseif ($PSCmdlet.ShouldProcess($nomGroupe, 'Créer le groupe')) {
        New-ADGroup -Name $nomGroupe -SamAccountName $nomGroupe -GroupScope Global -GroupCategory Security `
            -Path $ouGroupes -Description "Membres du service $service"
        Write-Log "Groupe créé : $nomGroupe" 'OK'
    }
}

# ---------------------------------------------------------------------------
# 3. Utilisateurs
# ---------------------------------------------------------------------------

$bilan = @{ UtilCrees = 0; UtilIgnores = 0; PostesDeplaces = 0; PostesIgnores = 0; Erreurs = 0 }

foreach ($u in $utilisateurs) {
    $nomComplet = "$($u.Prenom) $($u.Nom)"
    try {
        $prenomFiltre = $u.Prenom -replace "'", "''"
        $nomFiltre = $u.Nom -replace "'", "''"
        $existant = Get-ADUser -Filter "GivenName -eq '$prenomFiltre' -and Surname -eq '$nomFiltre'" -ErrorAction SilentlyContinue
        if ($existant) {
            Write-Log "Utilisateur déjà présent : $nomComplet ($($existant.SamAccountName))" 'IGNORE'
            $bilan.UtilIgnores++
            continue
        }

        $sam = Get-Identifiant -Prenom $u.Prenom -Nom $u.Nom
        $cible = $ouUsers[$u.Service]
        if ($PSCmdlet.ShouldProcess("$nomComplet ($sam) dans $cible", 'Créer l''utilisateur')) {
            if (-not $motDePasse) {
                $motDePasse = Read-Host "Mot de passe initial des comptes (changement obligatoire à la première connexion)" -AsSecureString
            }
            New-ADUser -Name $nomComplet `
                -GivenName $u.Prenom -Surname $u.Nom -DisplayName $nomComplet `
                -SamAccountName $sam -UserPrincipalName "$sam@$suffixeUPN" `
                -Title $u.Fonction -Department $u.Service `
                -Path $cible `
                -AccountPassword $motDePasse -ChangePasswordAtLogon $true -Enabled $true
            Add-ADGroupMember -Identity "GRP_$($u.Service)" -Members $sam
            Write-Log "Utilisateur créé : $nomComplet ($sam), service $($u.Service)" 'OK'
            $bilan.UtilCrees++
        }
    }
    catch {
        Write-Log "Échec pour $nomComplet : $($_.Exception.Message)" 'ERREUR'
        $bilan.Erreurs++
    }
}

# ---------------------------------------------------------------------------
# 4. Postes : du conteneur Computers vers <Service>\computers
# ---------------------------------------------------------------------------

foreach ($o in $ordinateurs) {
    try {
        $poste = Get-ADComputer -Filter "Name -eq '$($o.Nom)'" -ErrorAction SilentlyContinue
        if (-not $poste) {
            Write-Log "Poste introuvable dans l'annuaire : $($o.Nom) (vérifier le nom avec Get-ADComputer -Filter *)" 'ERREUR'
            $bilan.Erreurs++
            continue
        }
        $cible = $ouComputers[$o.Service]
        $parentActuel = ($poste.DistinguishedName -split ',', 2)[1]
        if ($parentActuel -eq $cible) {
            Write-Log "Poste déjà à sa place : $($o.Nom)" 'IGNORE'
            $bilan.PostesIgnores++
        }
        elseif ($PSCmdlet.ShouldProcess("$($o.Nom) : $parentActuel -> $cible", 'Déplacer le poste')) {
            Move-ADObject -Identity $poste.DistinguishedName -TargetPath $cible
            Write-Log "Poste déplacé : $($o.Nom) vers $cible" 'OK'
            $bilan.PostesDeplaces++
        }
    }
    catch {
        Write-Log "Échec pour le poste $($o.Nom) : $($_.Exception.Message)" 'ERREUR'
        $bilan.Erreurs++
    }
}

Write-Log ("Terminé : {0} utilisateur(s) créé(s), {1} ignoré(s) ; {2} poste(s) déplacé(s), {3} ignoré(s) ; {4} erreur(s). Journal : {5}" -f `
        $bilan.UtilCrees, $bilan.UtilIgnores, $bilan.PostesDeplaces, $bilan.PostesIgnores, $bilan.Erreurs, $LogPath)
