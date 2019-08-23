using namespace System.Net;

param($Timer); # Receive Timer from input binding

### Prepare to dump & zip ###
$mongodumpPath = "$env:HOME\site\wwwroot\mongo-to-azure\mongodump.exe";
$dumpName = "dump";
$dumpPath = "$env:HOME\$dumpName";

$formattedDate = Get-Date -Format $env:BackupDateFormat;
$zipName = "$formattedDate.zip";
$zipPath = "$env:HOME\$zipName";
#############################

### Dump & zip ##############
Write-Host "Started Dumping to $dumpPath";
& $mongodumpPath /h $env:Host /d $env:Database /u $env:User /p $env:Password /o $dumpPath --quiet;
Write-Host "Finished dumping";

Write-Host "Started zipping to $zipPath";
Add-Type -Assembly "System.IO.Compression.FileSystem";
[System.IO.Compression.ZipFile]::CreateFromDirectory($dumpPath, $zipPath);
Write-Host "Finished zipping";
#############################

#### Upload #################
$storageAccountName = "mongotoazure";
$containerName = "mongo-to-azure-container";

Write-Host "Started creating storage context for $storageAccountName";
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $env:StorageAccountKey;
Write-Host "Finished creating storage context";

Write-Host "Started uploading blob to $containerName";
[void](Set-AzStorageBlobContent -Container $containerName -File $zipPath -Blob $zipName -Context $storageContext); # Don't log the result
Write-Host "Finished uploading blob";
#############################

### Clean ###################
Remove-Item $dumpPath -Recurse;
Remove-Item $zipPath;
#############################

### Build email #############
$downloadLinkDayOfTheWeek = [Int] [DayOfWeek] $env:DownloadLinkDayOfTheWeek;
$currentDayOfTheWeek = [Int] (Get-Date).DayOfWeek;
$shouldGenerateDownloadLink = $currentDayOfTheWeek -eq $downloadLinkDayOfTheWeek;

$subject = "MongoDB Backup $formattedDate";
$content = "The MongoDB database ($env:Database) has been backed up to Azure Blob Storage."

If($shouldGenerateDownloadLink) {
    Write-Host "Started creating SAS token";
    $expiryDate = (Get-Date).AddHours($env:DownloadLinkLifespanInHours);
    $blobUri = New-AzStorageBlobSASToken -Container $containerName -Blob $zipName -Context $storageContext -Permission r -ExpiryTime $expiryDate -FullUri;
    Write-Host "Finished creating SAS token";
    $content += "The backup can be downloaded from $blobUri until $expiryDate.";
}

$body = @"
    '{
        "personalizations": [{"to": [{"email": "$env:ToEmailAddress"}]}],
        "from": {"email": "$env:FromEmailAddress"},
        "subject": "$subject",
        "content": [{"type": "text/plain", "value": "$content"}]
    }'
"@;

$header = @{"Authorization" = "Bearer $env:SendGridAPIKey"; "Content-Type" = "application/json"};
#############################

### Send email ##############
Write-Host "Started sending email";
[void](Invoke-RestMethod -Uri https://api.sendgrid.com/v3/mail/send -Method Post -Headers $header -Body $body); # Don't log the result
Write-Host "Finished sending email";
#############################