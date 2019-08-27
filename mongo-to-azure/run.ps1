using namespace System.Net;

param($Timer); # Receive Timer from input binding

$script:log = "";

function Write-Log {
	param( $line );
	$script:log += "$line`r`n";
	Write-Host $line;
}

### Prepare to dump and zip ###
$mongodumpPath = "$env:HOME\site\wwwroot\mongo-to-azure\mongodump.exe";
$dumpName = "dump";
$dumpPath = "$env:HOME\$dumpName";

$formattedDate = Get-Date -Format $env:BackupDateFormat;
$zipName = "$formattedDate.zip";
$zipPath = "$env:HOME\$zipName";
#############################

### Dump ####################
Write-Log -line "Started dumping to $dumpPath.";
$errorMessage = & $mongodumpPath /h $env:Host /d $env:Database /u $env:User /p $env:Password /o $dumpPath --quiet;
if ($LASTEXITCODE -ne 0) # If mongodump didn't succeed
{
    throw $errorMessage;
}
Write-Log -line "Finished dumping.";
#############################

### Zip #####################
Write-Log -line "Started zipping to $zipPath.";
Add-Type -Assembly "System.IO.Compression.FileSystem";
[System.IO.Compression.ZipFile]::CreateFromDirectory($dumpPath, $zipPath);
Write-Log -line "Finished zipping.";
#############################

#### Upload #################
$storageAccountName = "mongotoazure";
$containerName = "mongo-to-azure-container";

Write-Log -line "Started creating storage context for $storageAccountName.";
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $env:StorageAccountKey;
Write-Log -line "Finished creating storage context.";

Write-Log -line "Started uploading blob to $containerName.";
[void](Set-AzStorageBlobContent -Container $containerName -File $zipPath -Blob $zipName -Context $storageContext); # Don't output the result
Write-Log -line "Finished uploading blob.";
#############################

### Clean ###################
Write-Log -line "Removing dump and zip.";
Remove-Item $dumpPath -Recurse;
Remove-Item $zipPath;
Write-Log -line "Removed dump and zip.";
#############################

### Build email #############
$downloadLinkDayOfTheWeek = [Int] [DayOfWeek] $env:DownloadLinkDayOfTheWeek;
$currentDayOfTheWeek = [Int] (Get-Date).DayOfWeek;
$shouldGenerateDownloadLink = $currentDayOfTheWeek -eq $downloadLinkDayOfTheWeek;

$subject = "MongoDB Backup $formattedDate";
$content = "The MongoDB database ($env:Database) has been backed up to Azure Blob Storage."

if ($shouldGenerateDownloadLink) {
    Write-Log -line "Started creating SAS token.";
    $expiryDate = (Get-Date).AddHours($env:DownloadLinkLifespanInHours);
    $blobUri = New-AzStorageBlobSASToken -Container $containerName -Blob $zipName -Context $storageContext -Permission r -ExpiryTime $expiryDate -FullUri;
    Write-Log -line "Finished creating SAS token.";
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
Write-Log -line "Started sending email.";
[void](Invoke-RestMethod -Uri https://api.sendgrid.com/v3/mail/send -Method Post -Headers $header -Body $body); # Don't output the result
Write-Log -line "Finished sending email.";
#############################