<#
.SYNOPSIS
    Crée l'arborescence d'OU, les groupes de service et les utilisateurs du lab à partir d'un CSV.

.DESCRIPTION
    Structure créée dans le domaine courant :
        OU ECOLE-GN
          ├── OU Utilisateurs
          │     ├── OU Direction
          │     ├── OU Developpement
          │     ├── OU Comptabilite
          │     └── OU Marketing
          ├── OU Groupes      (un groupe de sécurité global GRP_<Service> par service)
          └── OU Ordinateurs

    Pour chaque ligne du CSV (Prenom, Nom, Service, Fonction), le script crée un compte
    prenom.nom (sans accents, en minuscules), le place dans l'OU de son service et l'ajoute
    au groupe du service. Le mot de passe initial est demandé à l'exécution et doit être
    changé à la première connexion.

    Le script est idempotent : un objet déjà présent est signalé et ignoré, on peut donc
    le relancer sans erreur. Il accepte -WhatIf pour simuler sans rien modifier.

.PARAMETER CsvPath
    Chemin du fichier CSV. Par défaut : utilisateurs.csv à côté du script.

.PARAMETER LogPath
    Chemin du journal d'exécution. Par défaut : un fichier horodaté à côté du script.

.EXAMPLE
    .\New-LabADStructure.ps1 -WhatIf
    Simule toutes les créations sans rien modifier.

.EXAMPLE
    .\New-LabADStructure.ps1
    Crée réellement les OU, les groupes et les utilisateurs.

.NOTES
    Auteur  : Richard Lamah
    Prérequis : module ActiveDirectory (RSAT), droits d'administrateur du domaine.
    Testé sur : Windows Server 2019, Windows PowerShell 5.1.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'utilisateurs.csv'),
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

# ---------------------------------------------------------------------------
# Contrôles préalables
# ---------------------------------------------------------------------------

if (-not (Test-Path $CsvPath)) { throw "Fichier CSV introuvable : $CsvPath" }

$utilisateurs = Import-Csv -Path $CsvPath -Encoding UTF8
$colonnes = 'Prenom', 'Nom', 'Service', 'Fonction'
$manquantes = $colonnes | Where-Object { $_ -notin $utilisateurs[0].PSObject.Properties.Name }
if ($manquantes) { throw "Colonnes absentes du CSV : $($manquantes -join ', ')" }

$domaine = Get-ADDomain
$racineDomaine = $domaine.DistinguishedName      # ex. DC=ecole-gn,DC=gn
$suffixeUPN = $domaine.DNSRoot                   # ex. ecole-gn.gn
$services = $utilisateurs.Service | Sort-Object -Unique

Write-Log "Domaine : $suffixeUPN ; $($utilisateurs.Count) utilisateurs ; services : $($services -join ', ')"

$motDePasse = $null
if (-not $WhatIfPreference) {
    $motDePasse = Read-Host "Mot de passe initial des comptes (changement obligatoire à la première connexion)" -AsSecureString
}

# ---------------------------------------------------------------------------
# 1. Arborescence d'OU
# ---------------------------------------------------------------------------

$ouRacine = New-OUSiAbsente -Nom 'ECOLE-GN' -Parent $racineDomaine
$ouUtilisateurs = New-OUSiAbsente -Nom 'Utilisateurs' -Parent $ouRacine
$ouGroupes = New-OUSiAbsente -Nom 'Groupes' -Parent $ouRacine
[void](New-OUSiAbsente -Nom 'Ordinateurs' -Parent $ouRacine)

$ouParService = @{}
foreach ($service in $services) {
    $ouParService[$service] = New-OUSiAbsente -Nom $service -Parent $ouUtilisateurs
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

$crees = 0; $ignores = 0; $erreurs = 0

foreach ($u in $utilisateurs) {
    $nomComplet = "$($u.Prenom) $($u.Nom)"
    try {
        $existant = Get-ADUser -Filter "GivenName -eq '$($u.Prenom -replace "'", "''")' -and Surname -eq '$($u.Nom -replace "'", "''")'" `
            -ErrorAction SilentlyContinue
        if ($existant) {
            Write-Log "Utilisateur déjà présent : $nomComplet ($($existant.SamAccountName))" 'IGNORE'
            $ignores++
            continue
        }

        $sam = Get-Identifiant -Prenom $u.Prenom -Nom $u.Nom
        if ($PSCmdlet.ShouldProcess("$nomComplet ($sam) dans $($ouParService[$u.Service])", 'Créer l''utilisateur')) {
            New-ADUser -Name $nomComplet `
                -GivenName $u.Prenom -Surname $u.Nom -DisplayName $nomComplet `
                -SamAccountName $sam -UserPrincipalName "$sam@$suffixeUPN" `
                -Title $u.Fonction -Department $u.Service `
                -Path $ouParService[$u.Service] `
                -AccountPassword $motDePasse -ChangePasswordAtLogon $true -Enabled $true
            Add-ADGroupMember -Identity "GRP_$($u.Service)" -Members $sam
            Write-Log "Utilisateur créé : $nomComplet ($sam), service $($u.Service)" 'OK'
            $crees++
        }
    }
    catch {
        Write-Log "Échec pour $nomComplet : $($_.Exception.Message)" 'ERREUR'
        $erreurs++
    }
}

Write-Log "Terminé : $crees créé(s), $ignores ignoré(s), $erreurs erreur(s). Journal : $LogPath"
