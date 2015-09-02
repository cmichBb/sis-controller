<#
.SYNOPSIS
  A controller for submitting feed files to Blackboard Learn's SIS Integration Framework
.DESCRIPTION
  Submits a set of one or more feed files to an SIS Integraion Endpoint on Blackboard Learn, monitors the status of those submissions, and optionally reports via email upon completion. Configurable via XML configuration file.
.EXAMPLE
  .\SIS_Snapshot_Controller.ps1 -ConfigFile D:\SIS_Snapshot\config.xml
.EXAMPLE
  .\SIS_Snapshot_Controller.ps1

  This usage assumes a configuration file exists at the current location named "config.xml"
.PARAMETER ConfigFile
  The full path to the configuration file to use. Defaults to config.xml in the working directory.
#>

param (
    [string]$ConfigFile = (Join-Path (Get-Location) "config.xml")
)

# Load configuration

if (Test-Path $ConfigFile) {
    [xml]$global:config = Get-Content $ConfigFile
} else {
    # Stop execution entirely!
    throw "No configuration file found. Specify a configuration file with the -ConfigFile parameter, or ensure that a config.xml file exists in the current directory"
}

$global:archiveFiles = @()

# Create the log file
$logFileName = "SIS_Snapshot_Controller-$(Get-Date -Format yyyy-MM-dd-HH-mm-ss).log"
if (!(Test-Path $global:config.settings.logging.logPath)) {
    New-Item $global:config.settings.logging.logPath -Type Directory
}
$global:logFile = Join-Path $global:config.settings.logging.logPath $logFileName
$global:archiveFiles += $global:logFile
New-Item $global:logFile -Type File
$global:configError = $null

# Define some helper functions

Function Write-Log {
    Param ([string]$logstring)
    Add-Content $global:logFile -value "[$(Get-Date -format 's')] $($logstring)"
    Write-Debug $logstring
}

Function Format-WordNumber {
    # Format-WordNumber -count 1 -singular "test" == 1 test
    # Format-WordNumber -count 2 -singular "exam" == 2 exams
    # Format-WordNumber -count 2 -singular "quiz" -plural "quizzes") == 2 quizzes

    Param ($count, $singular, $plural = $null)
    if ($count -eq 1) {
        $word = $singular
    } else {
        if ($plural -ne $null) {
            $word = $plural
        } else {
            # TODO: Handle other common pluralizations
            $word = $singular + "s"
        }
    }
    return "$count $word"
}

Add-Type -As System.IO.Compression.FileSystem

function New-ZipFile {
    #.Synopsis
    #  Create a new zip file, optionally appending to an existing zip...
    [CmdletBinding()]
    param(
        # The path of the zip to create
        [Parameter(Position=0, Mandatory=$true)]
        $ZipFilePath,
 
        # Items that we want to add to the ZipFile
        [Parameter(Position=1, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias("PSPath","Item")]
        [string[]]$InputObject = $Pwd,
 
        # Append to an existing zip file, instead of overwriting it
        [Switch]$Append,
 
        # The compression level (defaults to Optimal):
        #   Optimal - The compression operation should be optimally compressed, even if the operation takes a longer time to complete.
        #   Fastest - The compression operation should complete as quickly as possible, even if the resulting file is not optimally compressed.
        #   NoCompression - No compression should be performed on the file.
        [System.IO.Compression.CompressionLevel]$Compression = "Optimal"
    )
    begin {
        # Make sure the folder already exists
        [string]$File = Split-Path $ZipFilePath -Leaf
        [string]$Folder = $(if($Folder = Split-Path $ZipFilePath) { Resolve-Path $Folder } else { $Pwd })
        $ZipFilePath = Join-Path $Folder $File
        # If they don't want to append, make sure the zip file doesn't already exist.
        if(!$Append) {
            if(Test-Path $ZipFilePath) { Remove-Item $ZipFilePath }
        }
        $Archive = [System.IO.Compression.ZipFile]::Open( $ZipFilePath, "Update" )
    }
    process {
        foreach($path in $InputObject) {
            foreach($item in Resolve-Path $path) {
                # Push-Location so we can use Resolve-Path -Relative
                Push-Location (Split-Path $item)
                # This will get the file, or all the files in the folder (recursively)
                foreach($file in Get-ChildItem $item -Recurse -File -Force | % FullName) {
                    # Calculate the relative file path
                    $relative = (Resolve-Path $file -Relative).TrimStart(".\")
                    # Add the file to the zip
                    $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $file, $relative, $Compression)
                }
                Pop-Location
            }
        }
    }
    end {
        $Archive.Dispose()
        Get-Item $ZipFilePath
    }
}

# Load SIS-Powershell Module
try
{
    Import-Module SIS-Powershell -ErrorAction Stop
}
catch [Exception]
{
    Write-Log "Could not load SIS-Powershell Module. Please ensure that it is properly installed. See http://j.mp/sis-ps to obtain the module and installation instructions."
    throw "Could not load SIS-Powershell Module. Please ensure that it is properly installed. See http://j.mp/sis-ps to obtain the module and installation instructions."
}

#################################
#                               #
# Actual Controller Starts Here #
#                               #
#################################
Write-Log "************************************"
Write-Log "* Starting SIS Snapshot Controller *"
Write-Log "************************************"
Write-Log ""

$global:startTime = Get-Date

# Create Feed File Objects List
$global:feedFiles = @()
$global:config.settings.feedFiles.feedFile | ForEach-Object {
    $feedFile = New-Object PSObject -Property @{
            feedFilePath = $_.feedFilePath
            fileName = Split-Path $_.feedFilePath -Leaf
            recordType = $_.recordType
            operationType = $_.operationType
            statusID = $null
            recordCount = $null
            startTime = $null
            endTime = $null
            completeCount = $null
            errorCount = $null
            warningCount = $null
            consecutiveStatus = 0
            configError = $null
            statusAborted = $FALSE
            processed = $FALSE
    }
    $global:feedFiles += $feedFile
}

# Build Server Options string
$global:serverOptions = "-Server $($global:config.settings.server.serverAddress)"
$global:serverOptions += " -IntegrationUsername $($global:config.settings.server.integrationUsername)"
$global:serverOptions += " -IntegrationPassword $($global:config.settings.server.integrationPassword)"
if ($global:config.settings.server.nonStandardPort -ne "") { $global:serverOptions += " -Port $($global:config.settings.server.nonStandardPort)" }
if ($global:config.settings.server.useHTTPS.ToLower() -eq "false") { $global:serverOptions += " -UseHTTP" }
if ($global:config.settings.server.ignoreCertificateErrors.ToLower() -eq "true") { $global:serverOptions += " -ignoreCertificateErrors" }

# Per-File Loop
foreach ($feedFile in $global:feedFiles)
{

    $feedFile.startTime = Get-Date

    # Check File Existence
    if (Test-Path $feedFile.feedFilePath)
    {

        Write-Log "$($feedFile.fileName) Exists"
        $global:archiveFiles += Get-Item $feedFile.feedFilePath

        # Count Records
        if ($global:config.settings.server.integrationType -eq "SnapshotFlatFile")
        {
            $feedFile.recordCount = ((@(Get-Content $feedFile.feedFilePath)).length - 1)
        }
        elseif ($global:config.settings.server.integrationType -eq "SnapshotXMLFile")
        {
            [xml]$xmlfile = Get-Content $feedFile.feedFilePath
            $nodes = $xmlfile.SelectNodes("enterprise/child::*")
            $feedFile.recordCount = $nodes.count
        }
        else
        {
            $global:configError = "Invalid integration type specified in $(Resolve-Path $ConfigFile). Terminating further processing."
            Write-Log $global:configError
            break
        }
        
        if ($feedFile.recordCount -gt 0){

            Write-Log "$($feedFile.fileName) is a $($global:config.settings.server.integrationType) with $(Format-WordNumber -count $feedFile.recordCount -singular "record") "
            
            # Submit File
            $fileSubmitCommand = ""
            if ($global:config.settings.server.integrationType -eq "SnapshotFlatFile")
            {
                $fileSubmitCommand += "Send-SnapshotFlatFile $($global:serverOptions) -FeedFile $($feedFile.feedFilePath)"

                # Validate Record Type
                $validRecordTypes = "Course","CourseAssociation","CourseCategory","CourseCategoryMembership","CourseMembership","CourseStandardAssociation","HeirarchyNode","ObserverAssociation","Organization","OrganizationAssociation","OrganizationCategory","OrganizationCategoryMembership","OrganizationMembership","Person","Term","UserAssociation","UserSecondaryInstitutionRole"
                if ($feedFile.recordType -in $validRecordTypes) {
                    $fileSubmitCommand += " -RecordType $($feedFile.recordType)"
                }
                else
                {
                    $feedFile.configError = "Invalid record type ($($feedFile.recordType)) specified for $($feedFile.feedFilePath) in $(Resolve-Path $ConfigFile). This feed file will not be processed further"
                    Write-Log $feedFile.configError
                    Write-Log ""
                }

                # Validate Operation Type
                $validOperationTypes = "Store", "CompleteRefresh", "CompleteRefreshByDataSource", "Delete"
                if ($feedFile.operationType -in $validOperationTypes) {
                    $fileSubmitCommand += " -OperationType $($feedFile.operationType)"
                }
                else
                {
                    $feedFile.configError = "Invalid operation type ($($feedFile.operationType)) specified for $($feedFile.feedFilePath) in $(Resolve-Path $ConfigFile). This feed file will not be processed further"
                    Write-Log $feedFile.configError
                    Write-Log ""
                }
            }
            elseif ($global:config.settings.server.integrationType -eq "SnapshotXMLFile")
            {
                $fileSubmitCommand += "Send-SnapshotXMLFile $($global:serverOptions)"
            }

            if ($feedFile.configError -eq $null) {
                try
                {
                    $feedFile.statusID = Invoke-Expression $fileSubmitCommand
                    $feedFile.processed = $TRUE
                }
                catch [Exception]
                {
                    $feedFile.configError = "There was an error submitting $($feedFile.fileName): $($_.Exception.Message)"
                    Write-Log $feedFile.configError
                }
            }
            

            # Status Checking Loop
            if ($feedFile.processed -eq $TRUE)
            {

                $statusCheckBase = "Get-FeedFileStatus $($global:serverOptions) -IntegrationType $($global:config.settings.server.integrationType) -DataSetUID $($feedFile.statusID)"
                
                do
                {
                    # Wait
                    Start-Sleep -s $global:config.settings.server.pollDelay

                    try
                    {
                        # Check Status
                        $statusCheckCommand = "$($statusCheckBase) -Complete"
                        $currentComplete = Invoke-Expression $statusCheckCommand
                        Write-Log "$($currentComplete) of $($feedFile.recordCount) records complete."

                        # Consecutive Identical Complete Records Test
                        if ($currentComplete -eq $feedFile.completeCount)
                        {
                            $feedFile.consecutiveStatus += 1
                            Write-Log "There have now been $($feedFile.consecutiveStatus) consecutive identical status checks."
                        }
                        else
                        {
                            $feedFile.consecutiveStatus = 0
                            $feedFile.completeCount = $currentComplete
                        }
                        if ($feedFile.consecutiveStatus -eq $global:config.settings.server.statusCheckAbortThreashold)
                        {
                            $feedFile.statusAborted = $TRUE
                            Write-Log "Consecutive identical status check threashold of $($global:config.settings.server.statusCheckAbortThreashold) has been reached. Aborting further status checking of $($feedFile.fileName)"
                            Write-Log ""
                            break
                        }
                    }
                    catch [Exception]
                    {
                        Write-Log "There was an error checking the status: $($_.Exception.Message)"
                        $feedFile.consecutiveStatus += 1
                        if ($feedFile.consecutiveStatus -eq $global:config.settings.server.statusCheckAbortThreashold)
                        {
                            $feedFile.statusAborted = $TRUE
                            Write-Log "Consecutive identical status check threashold of $($global:config.settings.server.statusCheckAbortThreashold) has been reached. Aborting further status checking of $($feedFile.fileName)"
                            Write-Log ""
                            break
                        }
                    }

                } while ($feedFile.completeCount -ne $feedFile.recordCount)

                $errorCheckCommand = "$($statusCheckBase) -Error"
                $warningCheckCommand = "$($statusCheckBase) -Warning"
                $statusSummaryCommand = "$($statusCheckBase)"
                $feedFile.errorCount = (Invoke-Expression $errorCheckCommand)
                $feedFile.warningCount = (Invoke-Expression $warningCheckCommand)
                Write-Log "$($feedFile.fileName) completed processing."
                Write-Log "$(Invoke-Expression $statusSummaryCommand)"
                Write-Log ""
            }
            # End Status Checking Loop

        }
        else
        {
            Write-Log "File $($feedFile.fileName) exists, but was empty and was not processed."
            Write-Log ""   
        }
    }
    else
    {
        $feedFile.configError = "File $($feedFile.fileName) did not exist and was not processed."
        Write-Log $feedFile.configError
        Write-Log ""
    }

    $feedFile.endTime = Get-Date

} # End Per-File Loop

$global:endTime = Get-Date
Write-Log ""
Write-Log "Feed file submission and status checking complete"
Write-Log ""

# Archiving, if enabled

if ($global:config.settings.archiving.enableArchiving -eq "true") {
    
    $archiveFileName = "$(Get-Date -Format yyyy-MM-dd-HH-mm-ss)-snapshot-archive.zip"
    $archiveFile = Join-Path $global:config.settings.archiving.archivePath $archiveFileName
    
    Write-Log "Archiviving feed files and log (up to this point) to: $($archiveFile)"

    New-ZipFile -ZipFilePath $archiveFile -InputObject $global:logFile

    foreach ($feedFile in $global:feedFiles)
    {
        if (Test-Path $feedFile.feedFilePath) {
            New-ZipFile -ZipFilePath $archiveFile -InputObject $feedFile.feedFilePath -Append
        }
    }

    $archiveRetentionLimit = (Get-Date).AddDays(0-$global:config.settings.archiving.archiveRetentionPeriod)

    Write-Log ""
    Write-Log "Deleting archives created before $($archiveRetentionLimit)"
    Write-Log ""

    Get-ChildItem -Path $global:config.settings.archiving.archivePath -Include "*-snapshot-archive.zip" | Where-Object { $_.CreationTime -le $archiveRetentionLimit} | Remove-Item -Force
}

# Log rotation, cleanup

$logRetentionLimit = (Get-Date).AddDays(0-$global:config.settings.logging.logRetentionPeriod)

Write-Log ""
Write-Log "Deleting log files created before $($logRetentionLimit)"
Write-Log ""

$logFiles = Get-ChildItem -Path $global:config.settings.logging.logPath

foreach ($log in $logFiles)
{
    if ($log.CreationTime -le $logRetentionLimit) {
        Write-Log "Deleting log file: $($log.FullName)"
        Remove-Item $log.FullName -Force
    }
}


# | Where-Object { $_.CreationTime -le $logRetentionLimit} | Write-Log

Write-Log "Deleting feed files..."
foreach ($feedFile in $global:feedFiles)
{
    if (Test-Path $feedFile.feedFilePath) {
        Write-Log "...$($feedFile.fileName)"
        Remove-Item $feedFile.feedFilePath
    }
}
Write-Log ""

# Summary Reporting, if enabled

if ($global:config.settings.email.sendEmail -eq "true") {
    $body = ""
    $subject = $global:config.settings.email.subjectPrefix

    if ($global:configError -ne $null)
    {
        $subject += " Global Configuration Error. No Files Processed."
        $body = $global:configError
        Write-Log $body
        Write-Error $body
    }
    else
    {
        $hostname = hostname
        $duration = ($global:endTime - $global:startTime).TotalSeconds -as [Int]
        $body += "<p>This execution of the Powershell SIS Snapshot controller finished in $(Format-WordNumber -count $duration -singular "second"). Here's a summary of the feed files that were uploaded to $($global:config.settings.server.serverAddress):</p>`r`n"
        $body += "<table border=`"1`" cellspacing=`"0`" cellpadding=`"3`" width=`"100%`" style=`"max-width:450px`">`r`n"
        $body += "<tr><th>File</th><th>Duration</th><th>Summary</th></tr>`r`n"

        $errors = 0
        $warnings = 0

        foreach ($feedFile in $global:feedFiles)
        {

            if ($feedFile.processed -eq $TRUE)
            {
                
                $feedFileDuration = ($feedFile.endTime - $feedFile.startTime).TotalSeconds -as [Int]
                if ($feedFile.statusAborted -ne $TRUE)
                {
                    # Processed and status checking not aborted
                    $body += "<tr valign=`"top`"><td>$($feedFile.filename)</td><td>$(Format-WordNumber -count $feedFileDuration -singular "second")</td><td>$(Format-WordNumber -count $feedFile.recordCount -singular "record")<br />$(Format-WordNumber -count $feedFile.errorCount -singular "error")<br />$(Format-WordNumber -count $feedFile.warningCount -singular "warning")</td></tr>`r`n"
                    $errors += $feedFile.errorCount
                    $warnings += $feedFile.warningCount
                }
                else
                {
                    # Processed, but status checking aborted
                    $body += "<tr valign=`"top`"><td>$($feedFile.filename)</td><td>n/a</td><td>$(Format-WordNumber -count $feedFile.recordCount -singular "record")<br /><strong>Status checking was aborted for this file.</strong><br />Please check the status of this data set in Learn using Reference Code: $($feedfile.statusID)</td></tr>`r`n"
                    $warnings += $feedFile.recordCount
                }
            }
            else
            {
                # Not processed
                if ($feedFile.configError -ne $null) {
                    $body += "<tr valign=`"top`"><td>$($feedFile.filename)</td><td>n/a</td><td>$($feedFile.configError)</td></tr>`r`n"
                }
                $errors += 1
            }
        }

        $body += "</table>`r`n"
        $body += "<p>An archive of these feed files is available at $($archiveFile) on $($hostname)</p>"
        $body += "<p>See the Blackboard SIS logs or open the controller log file on $($hostname) for more context: $($global:logFile)</p>"
        $subject += " $($hostname): : $(Format-WordNumber -count $errors -singular "error") and $(Format-WordNumber -count $warnings -singular "warning")"
    }

    Write-Log " Sending summary report email."

    Send-MailMessage -To $global:config.settings.email.recipients.recipient -Subject $subject -From $global:config.settings.email.fromAddress -Body $body -SmtpServer $global:config.settings.email.smtpServer -BodyAsHtml

}

Write-Log ""
Write-Log "************************************"
Write-Log "* SIS Snapshot Controller Complete *"
Write-Log "************************************"