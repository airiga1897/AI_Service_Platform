param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$ControlRole = "orchestration",
    [string]$ControlAlias = "",
    [string]$OperatorDir = ".\operator",
    [string]$SshUser = "useradmin",
    [string]$SshKeyFile = "",
    [string]$RemoteNodesFile = "/tmp/ai-service-platform.nodes.csv",
    [string]$SoftetherDir = ".\operator\softether",
    [string]$RemoteSoftetherDir = "/tmp/ai-service-platform.softether",
    [string]$HaproxyDir = ".\operator\haproxy",
    [string]$RemoteHaproxyDir = "/tmp/ai-service-platform.haproxy",
    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh",
    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",
    [string]$PrepareInventoryScript = "tools/bootstrap/prepare_vps3_inventory.sh",
    [string]$VerifyControlScript = "tools/bootstrap/verify_control_node.sh",
    [string]$RemoteVerifyScript = "/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh",
    [string]$Include = "",
    [switch]$AutoAcceptHostKey,
    [switch]$FixKeyAcl,
    [switch]$SkipVerify,
    [switch]$SkipServicePlan
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "sync_nodes_to_vps3.ps1"
$args = @(
    "-NodesFile", $NodesFile,
    "-StateFile", $StateFile,
    "-ControlRole", $ControlRole,
    "-OperatorDir", $OperatorDir,
    "-SshUser", $SshUser,
    "-RemoteNodesFile", $RemoteNodesFile,
    "-SoftetherDir", $SoftetherDir,
    "-RemoteSoftetherDir", $RemoteSoftetherDir,
    "-HaproxyDir", $HaproxyDir,
    "-RemoteHaproxyDir", $RemoteHaproxyDir,
    "-RemotePrepareScript", $RemotePrepareScript,
    "-CreateInventoryScript", $CreateInventoryScript,
    "-PrepareInventoryScript", $PrepareInventoryScript,
    "-VerifyControlScript", $VerifyControlScript,
    "-RemoteVerifyScript", $RemoteVerifyScript
)
if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
if ($SshKeyFile) { $args += @("-SshKeyFile", $SshKeyFile) }
if ($Include) { $args += @("-Include", $Include) }
if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
if ($FixKeyAcl) { $args += "-FixKeyAcl" }
if ($SkipVerify) { $args += "-SkipVerify" }
if ($SkipServicePlan) { $args += "-SkipServicePlan" }

& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @args
exit $LASTEXITCODE
