using namespace System.Net;

param($Timer); # Receive Timer from input binding

$script:functionName = "mongo-to-azure";
$script:storageAccountName = "mongotoazure";
$script:containerName = "mongo-to-azure-container";

$script:lineBreak = "`r`n";
$script:log = "";
$script:dumpPath = "";
$script:zipPath = "";

function Write-Log {
	param( $Line );
	$script:log += "$Line$lineBreak";
	Write-Host $Line;
}

function New-DatedDownloadLink {
    param( $BlobName, $StorageContext );
    Write-Log -Line "Started creating SAS token.";
    $expiryDate = (Get-Date).AddHours($env:DownloadLinkLifespanInHours);
    $blobUri = New-AzStorageBlobSASToken -Container $script:containerName -Blob $BlobName -Context $StorageContext -Permission r -ExpiryTime $expiryDate -FullUri;
    Write-Log -Line "Finished creating SAS token.";
    return "The backup can be downloaded from $blobUri until $expiryDate.";
}

function New-EmailBody {
    param( $Subject, $Content );
    return @"
'{
    "personalizations": [{"to": [{"email": "$env:ToEmailAddress"}]}],
    "from": {"email": "$env:FromEmailAddress"},
    "subject": "$Subject",
    "content": [{"type": "text/html", "value": "$Content"}]
}'
"@;
}

function Send-SuccessEmail {
    param( $BlobName, $StorageContext );

    $subject = "Successful MongoDB Backup ($env:Database)";
    $content = "The MongoDB database ($env:Database) has been backed up to Azure Blob Storage. The backup's name is $BlobName."

    $downloadLinkDayOfTheWeek = [Int] [DayOfWeek] $env:DownloadLinkDayOfTheWeek;
    $currentDayOfTheWeek = [Int] (Get-Date).DayOfWeek;
    $shouldGenerateDownloadLink = $currentDayOfTheWeek -eq $downloadLinkDayOfTheWeek;

    if ($shouldGenerateDownloadLink) {
        $content += New-DatedDownloadLink -BlobName $BlobName -StorageContext $StorageContext;
    }

    Send-Email -Subject $subject -Content $content;
}

function Send-FailureEmail {
    param( $ErrorMessage );
    $subject = "FAILED MongoDB Backup ($env:Database)";
    $content = "The MongoDB database ($env:Database) was --NOT-- backed up to Azure Blob Storage.";
    $htmlContent = $content.replace("$lineBreak", "<br />"); # The SendGrid API uses <br /> tags for line breaks
    Send-Email -Subject $subject -Content $htmlContent;
}

function Send-Email {
    param( $Subject, $Content );
    $header = @{"Authorization" = "Bearer $env:SendGridAPIKey"; "Content-Type" = "application/json"};
    $body = New-EmailBody -Subject $Subject -Content $Content;
    Write-Log -Line "Started sending email.";
    [void](Invoke-RestMethod -Uri https://api.sendgrid.com/v3/mail/send -Method Post -Headers $header -Body $body); # Don't output the result
    Write-Log -Line "Finished sending email.";
}

try {
    ### Prepare to dump and zip ###
    $mongodumpPath = "$env:HOME\site\wwwroot\$script:functionName\mongodump.exe";
    $dumpName = "dump";
    $script:dumpPath = "$env:HOME\$dumpName";

    $formattedDate = Get-Date -Format $env:BackupDateFormat;
    $zipName = "$env:Database`_$formattedDate.zip"; # Escape the underscore
    $script:zipPath = "$env:HOME\$zipName";
    #############################

    ### Dump ####################
    Write-Log -Line "Started dumping to $script:dumpPath.";
    $dumpLogs = & $mongodumpPath /h $env:Host /d $env:Database /u $env:User /p $env:Password /o $script:dumpPath 2>&1; # mongodump writes logs to stderr, so capture them here
    if ($LASTEXITCODE -ne 0) # If mongodump didn't succeed
    {
        throw $dumpLogs;
    }
    Write-Log -Line "Finished dumping.";
    #############################

    ### Zip #####################
    Write-Log -Line "Started zipping to $script:zipPath.";
    Add-Type -Assembly "System.IO.Compression.FileSystem";
    [System.IO.Compression.ZipFile]::CreateFromDirectory($script:dumpPath, $script:zipPath);
    Write-Log -Line "Finished zipping.";
    #############################

    #### Upload #################
    Write-Log -Line "Started creating storage context for $script:storageAccountName.";
    $storageContext = New-AzStorageContext -StorageAccountName $script:storageAccountName -StorageAccountKey $env:StorageAccountKey;
    Write-Log -Line "Finished creating storage context.";

    Write-Log -Line "Started uploading blob to $script:containerName.";
    [void](Set-AzStorageBlobContent -Container $script:containerName -File $script:zipPath -Blob $zipName -Context $storageContext); # Don't output the result
    Write-Log -Line "Finished uploading blob.";
    #############################

    Send-SuccessEmail -BlobName $zipName -StorageContext $storageContext;
} catch {
    Write-Host $_; # Output exception
    Send-FailureEmail -ErrorMessage $_;
} finally {
    Write-Log -Line "Removing local dump and zip.";
    Remove-Item $script:dumpPath -Recurse;
    Remove-Item $script:zipPath;
    Write-Log -Line "Removed local dump and zip.";
}