param(
    [Parameter(Mandatory)][string]$Svg,
    [Parameter(Mandatory)][string]$Ico,
    [string]$Boost = "16:0.5, 20:0.3, 24:0.15",
    [int[]]$Sizes = @(16, 20, 24, 32, 48, 64, 128, 256),
    [string]$Browser = ""
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if ($Browser -eq "") {
    $Browser = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Browser) { throw "no Edge or Chrome found to rasterise the svg; pass -Browser" }
}

$svgText = [IO.File]::ReadAllText($Svg)
$boostTable = @{}
foreach ($part in $Boost -split ",") { if ($part -match '^\s*(\d+)\s*:\s*([\d.]+)\s*$') { $boostTable[[int]$Matches[1]] = [double]$Matches[2] } }

if (-not ($svgText -match 'fill="(#[0-9a-fA-F]{6})"')) { throw "no fill colour in the svg" }
$color = $Matches[1]
$jobs = @()
foreach ($size in $Sizes) {
    $fatten = if ($boostTable.ContainsKey($size)) { $boostTable[$size] } else { 0.0 }
    $scaled = $svgText -replace 'width="\d+" height="\d+"', "width=`"$size`" height=`"$size`""
    if ($fatten -gt 0) {
        $rx = New-Object regex('stroke="none"')
        $scaled = $rx.Replace($scaled, ('stroke="' + $color + '" stroke-width="' + $fatten.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture) + '" stroke-linejoin="round"'), 1)
    }
    $jobs += @{ size = $size; svg = $scaled }
}

$jsonJobs = ($jobs | ForEach-Object { '{"size":' + $_.size + ',"svg":' + (ConvertTo-Json $_.svg) + '}' }) -join ","
$html = @"
<!doctype html><meta charset="utf-8"><pre id="out"></pre><script>
const jobs = [$jsonJobs];
(async () => {
  const result = {};
  for (const job of jobs) {
    const img = new Image();
    await new Promise((ok, bad) => { img.onload = ok; img.onerror = () => bad(new Error("svg failed at " + job.size)); img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(job.svg); });
    const c = document.createElement("canvas"); c.width = job.size; c.height = job.size;
    c.getContext("2d").drawImage(img, 0, 0, job.size, job.size);
    result[job.size] = c.toDataURL("image/png").split(",")[1];
  }
  document.getElementById("out").textContent = JSON.stringify(result);
})().catch(e => { document.getElementById("out").textContent = "ERROR " + e.message; });
</script>
"@
$tmp = Join-Path $env:TEMP "svg2ico-$PID.html"
[IO.File]::WriteAllText($tmp, $html)
$dom = & $Browser --headless --disable-gpu --virtual-time-budget=5000 --dump-dom "file:///$($tmp -replace '\\', '/')" 2>$null | Out-String
Remove-Item $tmp
if (-not ($dom -match '(?s)<pre id="out">(.*?)</pre>')) { throw "no render output from Edge" }
$text = $Matches[1].Trim()
if ($text.StartsWith("ERROR")) { throw "render failed: $text" }
if ($text.Length -eq 0) { throw "Edge produced no output; the render did not finish in time" }
$pngs = ConvertFrom-Json $text

function Bmp-Frame([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $maskStride = [int](([math]::Ceiling($w / 32.0)) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40); $bw.Write([int32]$w); $bw.Write([int32]($h * 2)); $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]0); $bw.Write([uint32]($w * $h * 4 + $maskStride * $h)); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }
    for ($y = $h - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $w; $x++) {
            if ($bmp.GetPixel($x, $y).A -eq 0) { $i = [math]::Floor($x / 8); $row[$i] = $row[$i] -bor (0x80 -shr ($x % 8)) }
        }
        $bw.Write($row)
    }
    $bw.Flush()
    return ,$ms.ToArray()
}

$frames = @()
foreach ($size in $Sizes) {
    $png = [Convert]::FromBase64String($pngs.$size)
    if ($size -ge 256) {
        $frames += @{ size = $size; data = $png }
    } else {
        $bmp = New-Object System.Drawing.Bitmap((New-Object System.IO.MemoryStream(,$png)))
        if ($bmp.Width -ne $size) { throw "Edge rendered $($bmp.Width) for $size" }
        $frames += @{ size = $size; data = (Bmp-Frame $bmp) }
    }
}

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.size -ge 256) { 0 } else { $f.size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$f.data.Length); $w.Write([uint32]$offset)
    $offset += $f.data.Length
}
foreach ($f in $frames) { $w.Write([byte[]]$f.data) }
$w.Flush()
[IO.File]::WriteAllBytes($Ico, $out.ToArray())
"wrote $Ico ($($out.Length) bytes): " + ($Sizes -join ", ")
