function New-A3WorkflowLogger {
 [CmdletBinding()]
 param([string]$LogPath,[ValidateSet('Debug','Info','Warning','Error')][string]$MinimumLevel='Info',[switch]$Console)
 $levels=@{Debug=0;Info=1;Warning=2;Error=3}
 if($LogPath){$parent=Split-Path -Parent $LogPath;if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}}
 [pscustomobject]@{LogPath=$LogPath;MinimumLevel=$MinimumLevel;Console=[bool]$Console;Levels=$levels}
}
function Write-A3WorkflowLog {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Logger,[Parameter(Mandatory=$true)][ValidateSet('Debug','Info','Warning','Error')][string]$Level,[Parameter(Mandatory=$true)][string]$Message,[string]$Module='Core',[hashtable]$Data)
 if($Logger.Levels[$Level] -lt $Logger.Levels[$Logger.MinimumLevel]){return}
 $entry=[ordered]@{timestamp=[DateTime]::UtcNow.ToString('o');level=$Level;module=$Module;message=$Message;data=$Data}
 $line=$entry|ConvertTo-Json -Depth 12 -Compress
 if($Logger.LogPath){Add-Content -LiteralPath $Logger.LogPath -Value $line -Encoding UTF8}
 if($Logger.Console){switch($Level){'Debug'{Write-Host $Message -ForegroundColor DarkGray}'Info'{Write-Host $Message -ForegroundColor Gray}'Warning'{Write-Warning $Message}'Error'{Write-Error $Message -ErrorAction Continue}}}
}