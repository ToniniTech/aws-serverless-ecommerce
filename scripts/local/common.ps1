$ErrorActionPreference = "Stop"

$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$script:TerraformRoot = Join-Path $script:RepositoryRoot "infrastructure/terraform/local"
$script:TerraformExecutable = Join-Path $script:RepositoryRoot ".tools/terraform-1.15.8/terraform.exe"

function Enter-RepositoryRoot {
    Set-Location -LiteralPath $script:RepositoryRoot
}

function Assert-CommandSucceeded {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LocalTerraform {
    if (Test-Path -LiteralPath $script:TerraformExecutable) {
        return $script:TerraformExecutable
    }

    $terraform = Get-Command terraform -ErrorAction SilentlyContinue
    if ($null -eq $terraform) {
        throw "Terraform was not found. Keep the bundled .tools copy or install Terraform 1.9+."
    }
    return $terraform.Source
}

function Get-TerraformOutput {
    param([Parameter(Mandatory = $true)][string]$Name)

    $terraform = Get-LocalTerraform
    $value = & $terraform "-chdir=$script:TerraformRoot" output -raw $Name
    Assert-CommandSucceeded "Reading Terraform output '$Name'"
    return ($value -join "`n").Trim()
}

function Invoke-LocalAws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Enter-RepositoryRoot
    $result = & docker compose exec -T localstack awslocal @Arguments
    Assert-CommandSucceeded "Local AWS command: $($Arguments -join ' ')"
    return ($result -join "`n")
}

function Invoke-LocalAwsWithJsonInput {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$JsonOption,
        [Parameter(Mandatory = $true)][string]$Json
    )

    Enter-RepositoryRoot

    $previousOutputEncoding = $OutputEncoding
    try {
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $cleanJson = $Json.TrimStart([char]0xFEFF)

        $result = $cleanJson | & docker compose exec -T localstack `
            awslocal @Arguments $JsonOption file:///dev/stdin

        Assert-CommandSucceeded `
            "Local AWS command with JSON input: $($Arguments -join ' ') $JsonOption"

        return ($result -join "`n")
    }
    finally {
        $OutputEncoding = $previousOutputEncoding
    }
}

function Clear-LocalQueue {
    param([Parameter(Mandatory = $true)][string]$QueueUrl)

    [void](Invoke-LocalAws -Arguments @("sqs", "purge-queue", "--queue-url", $QueueUrl))
}

function Receive-LocalMessage {
    param(
        [Parameter(Mandatory = $true)][string]$QueueUrl,
        [int]$VisibilityTimeout = 2,
        [int]$WaitTimeSeconds = 2
    )

    $json = Invoke-LocalAws -Arguments @(
        "sqs", "receive-message",
        "--queue-url", $QueueUrl,
        "--max-number-of-messages", "1",
        "--visibility-timeout", $VisibilityTimeout.ToString(),
        "--wait-time-seconds", $WaitTimeSeconds.ToString(),
        "--attribute-names", "All"
    )
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    $response = $json | ConvertFrom-Json
    if ($null -eq $response.Messages -or $response.Messages.Count -eq 0) {
        return $null
    }
    return $response.Messages[0]
}

function Remove-LocalMessage {
    param(
        [Parameter(Mandatory = $true)][string]$QueueUrl,
        [Parameter(Mandatory = $true)][string]$ReceiptHandle
    )

    [void](Invoke-LocalAws -Arguments @(
        "sqs", "delete-message",
        "--queue-url", $QueueUrl,
        "--receipt-handle", $ReceiptHandle
    ))
}

function Invoke-LocalLambda {
    param(
        [Parameter(Mandatory = $true)][string]$FunctionName,
        [Parameter(Mandatory = $true)][string]$Payload
    )

    $remoteOutput = "/tmp/lambda-$([guid]::NewGuid().ToString('N')).json"
    Enter-RepositoryRoot
    $metadataOutput = $Payload | & docker compose exec -T localstack awslocal lambda invoke `
        --function-name $FunctionName `
        --payload file:///dev/stdin `
        $remoteOutput
    Assert-CommandSucceeded "Invoking local Lambda $FunctionName"
    $metadataJson = $metadataOutput -join "`n"
    $metadata = $metadataJson | ConvertFrom-Json

    Enter-RepositoryRoot
    $payloadOutput = & docker compose exec -T localstack cat $remoteOutput
    Assert-CommandSucceeded "Reading local Lambda response for $FunctionName"
    [void](& docker compose exec -T localstack rm -f $remoteOutput)

    $payloadText = ($payloadOutput -join "`n")
    if ($null -ne $metadata.FunctionError) {
        throw "Local Lambda $FunctionName failed: $payloadText"
    }
    return $payloadText
}

function Invoke-LocalPostgresScalar {
    param([Parameter(Mandatory = $true)][string]$Sql)

    Enter-RepositoryRoot
    $result = & docker compose exec -T payment-postgres `
        psql -U payment_local -d payments -v ON_ERROR_STOP=1 -tAc $Sql
    Assert-CommandSucceeded "Local PostgreSQL query"
    return ($result -join "`n").Trim()
}

function Suspend-LocalEventSourceMappings {
    $json = Invoke-LocalAws -Arguments @(
        "lambda", "list-event-source-mappings",
        "--query", "EventSourceMappings[].{UUID:UUID,State:State}",
        "--output", "json"
    )
    $allMappings = ConvertFrom-Json -InputObject $json
    $enabledMappingIds = @()
    foreach ($mapping in $allMappings) {
        if ($mapping.State -ne "Enabled") {
            continue
        }
        $mappingId = [string]$mapping.UUID
        [void](Invoke-LocalAws -Arguments @(
            "lambda", "update-event-source-mapping",
            "--uuid", $mappingId,
            "--no-enabled"
        ))
        $enabledMappingIds += $mappingId
    }
    if ($enabledMappingIds.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
    return $enabledMappingIds
}

function Resume-LocalEventSourceMappings {
    param([string[]]$MappingIds)

    foreach ($mappingId in $MappingIds) {
        [void](Invoke-LocalAws -Arguments @(
            "lambda", "update-event-source-mapping",
            "--uuid", $mappingId,
            "--enabled"
        ))
    }
}
