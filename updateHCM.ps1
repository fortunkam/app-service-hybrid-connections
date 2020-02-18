param ($connectionStrings)

$filePath="C:\Program Files\Microsoft\HybridConnectionManager 0.7\Microsoft.HybridConnectionManager.Listener.exe.config"
#$filePath="C:\dev\web\hybrid-connections\Demo.config"
[xml]$xml = Get-Content $filePath

#base64decode the param
#Parse the connectionStrings
$option = [System.StringSplitOptions]::RemoveEmptyEntries
$connStrArray = $connectionStrings.Split("|",$option)

foreach($i in $connStrArray)
{
    $hc1=$xml.CreateElement("hybridConnection")
    $hc1.SetAttribute("connectionString", $i)
    $elem = $xml.configuration.hybridConnections
    $n = $elem.SelectSingleNode("connectionStrings")
    $n.AppendChild($hc1)
}

$xml.Save($filePath)

#Write-Host $xml.OuterXml
