param (
    [string]$WorkingDir,
    [string]$OutputDir = (Get-Location)
)
# Function that scrapes information from the ZTIGather log files
function Find-MachineInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDir_base
    )
    $MDT_Info = @{ }
    # Pulls directory separator from dotnet for crossplatform support
    $LogDir_full = Join-Path -Path "$LogDir_base" -ChildPath "ZTIGather.log" 
    # Bring the raw text into the shell and use regular expressions to pull relevant data
    Get-Content "$LogDir_full" -Raw | ForEach-Object {
        $_ -cmatch '(?sm)(?:Property SerialNumber is now = )(?''serialnumber''[\w|-]+)' >$null
        $MDT_Info.Add('serialnumber', $matches['serialnumber'])
        $_ -cmatch '(?:Model is now = )(?''model''[\w|\d|\s]+)' >$null
        $MDT_Info.Add('model', $matches['model'])
    }
    # Return a hash table with the relevant data
    return $MDT_Info
}

function Get-DeploymentTime {
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$ContentString,
        [Parameter(Mandatory = $true)]
        [System.Boolean]$Success_Bool
    )

    #Create a timespan object for later use
    $time_threshold = New-TimeSpan -Days 5
    # Define regexs used in parsing
    $start_regex = '(?:LTI beginning deployment]LOG]!><time=\")(?''time''[\d|:]+)(?:[.|0|+|" | ]{9}) date=\"(?''date''[\d|-]{10})'
    $end_success_regex = '(?:LTI deployment completed successfully.*<time=\")(?''time''[\d|:]+)(?:[.|0|+|" | ]{9}) date=\"(?''date''[\d|-]{10})'
    $end_failure_regex = '(?:Litetouch deployment failed.*!><time=\")(?''time''[\d|:]+)(?:[.|0|+|" | ]{9}) date=\"(?''date''[\d|-]{10})'
    # Call dotnet regex match function for multiline regex support
    $start_match = [regex]::Match($content, $start_regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    # If Regex is successful add save values to variables, Else use powershells built-in regex to pull starttime from first line of file
    if ($start_match.success) {
        $start_datetime = $start_match.Groups['date'].Value.Replace('-', '/') + ' ' + $start_match.Groups['time']
        $start_date = $start_match.Groups['date'].Value.Replace('-', '/')
        $start_time = $start_match.Groups['time'].Value
    }
    else {
        $ContentString.Split("`n")[0] -cmatch '(?:LOG]!><time=\")(?''time''[\d | :]+)(?:[. | 0 | + | " | ]{9}) date=\"(?''date''[\d | -]{10})' >$null
        $start_date = $Matches['date']
        $start_time = $Matches['time']
        $start_datetime = $matches['date'].Replace('-', '/') + ' ' + $matches['time']
    }
    # Pull end time based on success or failure
    if ($Success_Bool) {
        $end_match = [regex]::Match($content, $end_success_regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    }
    else {
        $end_match = [regex]::Match($content, $end_failure_regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    }

    # If end time matching was successful assign values to variables
    if ($end_match.success) {
        $end_datetime = $end_match.Groups['date'].Value.Replace('-', '/') + ' ' + $end_match.Groups['time']
        $end_date = $end_match.Groups['date'].Value.Replace('-', '/')
        $end_time = $end_match.Groups['time'].Value
    }
    # If start time and endtime regexs were successful, create datetime objects
    if ($start_match.success -and $end_match.success) {
        $start_datetime_obj = [System.Convert]::ToDateTime($start_datetime)
        $end_datetime_obj = [System.Convert]::ToDateTime($end_datetime)
        # If elapsed time is less than the timespan object created and is not 0 set value to elapsed time, else assign 'N/A'
        if (($end_datetime_obj - $start_datetime_obj -lt $time_threshold) -and ($end_datetime_obj - $start_datetime_obj -gt $(New-TimeSpan -Seconds 1))) {
            $elapsed_time = "{0:g}" -f ($end_datetime_obj - $start_datetime_obj)
        }
        else {
            $elapsed_time = 'N/A'
        }
    }
    else {
        $elapsed_time = 'N/A'
    }
    return $start_date, $start_time, $end_date, $end_time, $elapsed_time
}

# Initialize Array Objects
$Success_Array = @()
$Error_Array = @()

# Bring the raw text into the shell and use regular expressions to pull relevant data and use conditional regex to evaluate which array to add information to
Get-ChildItem -Path "$WorkingDir" -Filter BDD.log -Recurse | ForEach-Object {
    if ($_.Length -gt 0) {
        $Content = Get-Content $_.FullName -Raw
        $ParentString = $Content.PSParentPath
        $Content.PSParentPath
        if ( $Content -cmatch 'LTI deployment completed successfully') {
            $Success_Array += ((Find-MachineInfo($ParentString)))
            $Success_Array[-1].Add('success', $true)
            $Content -cmatch "(?:UserID is now = )(?'username'[. | \w]+)(?:]LOG])" >$null
            $Success_Array[$Success_Array.Length - 1].Add('username', $Matches['username'])
            $Content -cmatch "(?:Property TaskSequenceID is now = )(?'tasksequence_number'[\d]+)(?:]LOG])" >$null
            $Success_Array[$Success_Array.Length - 1].Add('tasksequence_number', $Matches['tasksequence_number'])
            $Content -cmatch "(?:Application )(?'application'[.|\w|\d| |]+)(?: returned an unexpected return code: )(?'application_error_code'\d+)" >$null
            $Success_Array[$Success_Array.Length - 1].Add('application', $Matches['application'])
            $Success_Array[$Success_Array.Length - 1].Add('application_error_code', $Matches['application_error_code'])
            $Content -cmatch "(?:InstallFromPath:.*)(?:\\)(?'wim_file'[\d|\w\|_]+.wim)(?:\]LOG\])" >$null
            $Success_Array[$Success_Array.Length - 1].Add('wim_file', $Matches['wim_file'])
            #Call Get-DeploymentTime function and assign values to the array
            $TimeObjs = Get-DeploymentTime $Content $true
            $Success_Array[-1].Add("start_date", $TimeObjs[0])
            $Success_Array[-1].Add("start_time", $TimeObjs[1])
            $Success_Array[-1].Add("end_date", $TimeObjs[2])
            $Success_Array[-1].Add("end_time", $TimeObjs[3])
            $Success_Array[-1].Add("elapsed_time", $TimeObjs[4].TrimStart('-'))
        }
        else {
            $Error_Array += ((Find-MachineInfo($ParentString)))
            $Error_Array[-1].Add('success', $false)
            $Content -cmatch '<!\[LOG\[FAILURE \( (?''failure''\d+) \)' >$null
            $Error_Array[$Error_Array.Length - 1].Add('failure', $Matches['failure'])
            $Content -cmatch "(?:UserID is now = )(?'username'[. | \w]+)(?:]LOG])" >$null
            $Error_Array[$Error_Array.Length - 1].Add('username', $Matches['username'])
            $Content -cmatch "(?:Property TaskSequenceID is now = )(?'tasksequence_number'[\d]+)(?:]LOG])" >$null
            $Error_Array[$Error_Array.Length - 1].Add('tasksequence_number', $Matches['tasksequence_number'])
            $Content -cmatch "(?:Application )(?'application'[.|\w|\d| |]+)(?: returned an unexpected return code: )(?'application_error_code'\d+)" >$null
            $Error_Array[$Error_Array.Length - 1].Add('application', $Matches['application'])
            $Error_Array[$Error_Array.Length - 1].Add('application_error_code', $Matches['application_error_code'])
            $Content -cmatch "(?:InstallFromPath:.*)(?:\\)(?'wim_file'[\d|\w\|_]+.wim)(?:\]LOG\])" >$null
            $Error_Array[$Error_Array.Length - 1].Add('wim_file', $Matches['wim_file'])
            $TimeObjs = Get-DeploymentTime $Content $false
            $Error_Array[-1].Add("start_date", $TimeObjs[0])
            $Error_Array[-1].Add("start_time", $TimeObjs[1])
            $Error_Array[-1].Add("end_date", $TimeObjs[2])
            $Error_Array[-1].Add("end_time", $TimeObjs[3])
            $Error_Array[-1].Add("elapsed_time", $TimeObjs[4])
        }
    }
}

# Build new array from the separate arrays
$Full_Array = @()
$Full_Array += $Success_Array | ForEach-Object { $_ }
$Full_Array += $Error_Array | ForEach-Object { $_ }

# Create format strings
$output_format = @{N = "Date"; e = { $_.start_date } }, @{N = "Start Time"; e = { $_.start_time } }, @{N = "Elapsed Time"; e = { $_.elapsed_time } },
@{N = "Serial Number"; e = { $_.serialnumber } }, @{N = "Model"; E = { $_.model } }, @{N = "User Name"; e = { $_.Username } },
@{N = "Task Sequence Error Code"; e = { $_.failure } }, @{N = "Task Sequence Number"; e = { $_.tasksequence_number } }, @{N = "WIM File"; e = { $_.wim_file } },
@{N = "Failed Application"; e = { $_.application } }, @{N = "Application Error Code"; e = { $_.application_error_code } }
$output_success_format = $output_format + @{N = "Success"; e = { $_.success } }

# Set output paths with cross plat folder structure
$CSVOutputDir = Join-Path -Path "$OutputDir" -ChildPath "CSV"
$JsonOutputDir = Join-Path -Path "$OutputDir" -ChildPath "Json"

# Create directories, ignore errors if they're already there
New-Item -ItemType Directory -Path "$CSVOutputDir" -ErrorAction SilentlyContinue >$null
New-Item -ItemType Directory -Path "$JsonOutputDir" -ErrorAction SilentlyContinue >$null

$today = Get-Date -Format "%M-%d-%y"

# Export information to CSV files with prettied up column headers
$Success_Array | ForEach-Object { new-object psobject -Property $_ } | select-object -Property $output_format | Sort-Object -Property date, time | 
Export-csv $(Join-Path -Path "$CSVOutputDir" -ChildPath "Successful_Deployments_$today.csv") -Encoding UTF8 -NoTypeInformation -Force
$Error_Array | ForEach-Object { new-object psobject -Property $_ } | select-object -Property $output_format | Sort-Object -Property date, time | 
Export-csv $(Join-Path -Path "$CSVOutputDir" -ChildPath "Failed_Deployments_$today.csv") -Encoding UTF8 -NoTypeInformation -Force
$Full_Array | ForEach-Object { new-object psobject -Property $_ } | select-object -Property $output_success_format | Sort-Object -Property date, time | 
Export-csv $(Join-Path -Path "$CSVOutputDir" -ChildPath "Full_Deployment_list_$today.csv") -Encoding UTF8 -NoTypeInformation -Force

# Export to Json
$Error_Array | ConvertTo-Json | Out-File $(Join-Path -Path "$JsonOutputDir" -ChildPath "ErrorLog_$today.json") -Encoding utf8 -Force
$Success_Array | Convertto-Json | Out-File $(Join-Path -Path "$JsonOutputDir" -ChildPath "SuccessLog_$today.json") -Encoding utf8 -Force
$Full_Array | Convertto-Json | Out-File $(Join-Path -Path "$JsonOutputDir" -ChildPath "Full_Deployment_$today.json") -Encoding utf8 -Force