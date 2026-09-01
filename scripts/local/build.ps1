param([switch]$SkipTests)

. (Join-Path $PSScriptRoot "common.ps1")

Enter-RepositoryRoot
$arguments = @("clean", "package")
if ($SkipTests) {
    $arguments += "-DskipTests"
}

& (Join-Path $script:RepositoryRoot "mvnw.cmd") @arguments
Assert-CommandSucceeded "Maven Lambda build"

$artifacts = @(
    "payment-order-created-lambda/target/payment-order-created-lambda.jar",
    "order-payment-result-lambda/target/order-payment-result-lambda.jar",
    "notification-demo-lambda/target/notification-demo-lambda.jar",
    "saga-orchestration-lambda/target/saga-orchestration-lambda.jar"
)
foreach ($artifact in $artifacts) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $artifact))) {
        throw "Expected Lambda artifact was not created: $artifact"
    }
}

Write-Host "All shaded Java Lambda artifacts are ready."
