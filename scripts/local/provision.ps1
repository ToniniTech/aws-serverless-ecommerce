. (Join-Path $PSScriptRoot "common.ps1")

Enter-RepositoryRoot

try {
    [void](Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:4566/_localstack/health" -TimeoutSec 5)
} catch {
    throw "LocalStack is not reachable. Run scripts/local/start.ps1 first."
}

$terraform = Get-LocalTerraform
& $terraform "-chdir=$script:TerraformRoot" init
Assert-CommandSucceeded "Terraform init"

& $terraform "-chdir=$script:TerraformRoot" apply -auto-approve
Assert-CommandSucceeded "Terraform apply against LocalStack"

Write-Host "Local messaging, Lambda, and Step Functions resources are provisioned."
Write-Host "Endpoint: http://localhost:4566 (fake account 000000000000)"
