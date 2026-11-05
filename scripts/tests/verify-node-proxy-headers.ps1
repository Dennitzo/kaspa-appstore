param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("kaspa-headers-" + [guid]::NewGuid().ToString('N'))
$prefix = 'kaspa-header-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$network = "$prefix-net"
$containers = @("$prefix-api", "$prefix-node", "$prefix-dashboard")
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8($Path, $Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Invoke-Docker {
    $output = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed: $($output -join "`n")" }
    return $output
}

try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $apiSource = [System.IO.File]::ReadAllText((Join-Path $root 'kaspa-node/api/app.py'))
    $nodeConfig = [System.IO.File]::ReadAllText((Join-Path $root 'kaspa-node/frontend/nginx.conf'))
    $dashboardConfig = [System.IO.File]::ReadAllText((Join-Path $root 'rusty-kaspa-bridge-dashboard/nginx.dashboard.conf'))
    if ($apiSource -match '(?m)^\s*response\.headers\["Expires"\]\s*=') { throw 'The current Flask hook still sets Expires.' }
    if ($nodeConfig -notmatch "proxy_hide_header\s+'Expires'") { throw 'Current node configuration must hide upstream Expires.' }
    if (-not $dashboardConfig.Contains('host.docker.internal:19112')) { throw 'Expected dashboard node upstream not found.' }
    $oldNodeConfig = $nodeConfig -replace "(?m)^\s*proxy_hide_header 'Expires';\s*\r?\n", ''
    $oldApiSource = $apiSource.Replace('    response.headers["Pragma"] = "no-cache"', "    response.headers[`"Pragma`"] = `"no-cache`"`n    response.headers[`"Expires`"] = `"0`"")
    if ($oldApiSource -eq $apiSource) { throw 'Unable to construct the old Flask hook for the negative control.' }
    $dashboardConfig = $dashboardConfig.Replace('host.docker.internal:19112', 'node:19112')

    # Import the real app and run its real status endpoint and after_request hook.
    # Only Docker discovery is mocked, avoiding access to the host Docker socket.
    $bootstrap = @'
import sys, types
fake_docker = types.ModuleType('docker')
fake_docker.from_env = lambda: None
sys.modules['docker'] = fake_docker
import app
class Result:
    exit_code = 0
    output = b'0 /app/data'
class Container:
    attrs = {'State': {'Status': 'running'}, 'Config': {'Cmd': [], 'Image': 'test'}}
    def logs(self, **kwargs): return b''
    def exec_run(self, *args, **kwargs): return Result()
app._resolve_container = lambda service: Container()
app.app.run(host='0.0.0.0', port=8000)
'@
    $probe = @'
import http.client, json, sys
c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=5)
c.request('GET', sys.argv[3])
r = c.getresponse()
print(json.dumps({'status': r.status, 'expires': [v for k, v in r.getheaders() if k.lower() == 'expires']}))
r.read()
'@
    Write-Utf8 (Join-Path $temp 'bootstrap.py') $bootstrap
    Write-Utf8 (Join-Path $temp 'probe.py') $probe
    Write-Utf8 (Join-Path $temp 'dashboard.conf') $dashboardConfig
    Invoke-Docker network create --internal $network | Out-Null

    $cases = @(
        @{ Name = 'current API and node'; OldApi = $false; OldNode = $false; Duplicate = $false },
        @{ Name = 'current API and old node'; OldApi = $false; OldNode = $true; Duplicate = $false },
        @{ Name = 'old API and current node'; OldApi = $true; OldNode = $false; Duplicate = $false },
        @{ Name = 'old API and old node (negative control)'; OldApi = $true; OldNode = $true; Duplicate = $true }
    )
    foreach ($case in $cases) {
        Write-Utf8 (Join-Path $temp 'app.py') $(if ($case.OldApi) { $oldApiSource } else { $apiSource })
        Write-Utf8 (Join-Path $temp 'node.conf') $(if ($case.OldNode) { $oldNodeConfig } else { $nodeConfig })
        Invoke-Docker run -d --name $containers[0] --network $network --network-alias kaspa-api --network-alias stratum-bridge --mount "type=bind,source=$temp,target=/test,readonly" --workdir /test dennitzo/kaspa-node-api:latest python /test/bootstrap.py | Out-Null
        Invoke-Docker run -d --name $containers[1] --network $network --network-alias node --mount "type=bind,source=$temp/node.conf,target=/etc/nginx/conf.d/default.conf,readonly" --entrypoint nginx dennitzo/kaspa-node-ui:latest -g 'daemon off;' | Out-Null
        Invoke-Docker run -d --name $containers[2] --network $network --mount "type=bind,source=$temp/dashboard.conf,target=/etc/nginx/conf.d/default.conf,readonly" --entrypoint nginx dennitzo/kaspa-stratum-dashboard:latest -g 'daemon off;' | Out-Null
        $ready = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $raw = & docker exec $containers[0] python /test/probe.py $containers[2] 80 /api/node-status 2>$null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw "Dashboard did not become ready for $($case.Name)." }
        $dashboard = $raw | ConvertFrom-Json
        $node = (Invoke-Docker exec $containers[0] python /test/probe.py node 19112 /api/status) | ConvertFrom-Json
        $logs = (& docker logs $containers[2] 2>&1 | Out-String)
        $warn = $logs -match 'upstream sent duplicate header line: "Expires: 0"'
        $expectedNodeCount = if ($case.Duplicate) { 2 } else { 1 }
        if ($node.status -ne 200 -or @($node.expires).Count -ne $expectedNodeCount -or $dashboard.status -ne 200 -or @($dashboard.expires).Count -ne 1 -or $warn -ne $case.Duplicate) {
            throw "Unexpected result for $($case.Name): node=$($node | ConvertTo-Json -Compress), dashboard=$($dashboard | ConvertTo-Json -Compress), warning=$warn`n$logs"
        }
        Write-Host "PASS $($case.Name): node Expires=$(@($node.expires).Count), dashboard Expires=$(@($dashboard.expires).Count), duplicate warning=$warn"
        Invoke-Docker rm -f @containers | Out-Null
    }
} finally {
    & docker rm -f @containers 2>$null | Out-Null
    & docker network rm $network 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) {
        $resolvedTemp = (Resolve-Path -LiteralPath $temp).ProviderPath
        $expectedTemp = [System.IO.Path]::GetFullPath($temp).TrimEnd('\', '/')
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not [string]::Equals($resolvedTemp, $expectedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $resolvedTemp.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTemp) -notlike 'kaspa-headers-*') {
            throw "Refusing to remove unexpected temporary directory: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
