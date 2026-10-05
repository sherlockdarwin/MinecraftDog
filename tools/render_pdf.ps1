param(
    [Parameter(Mandatory = $true)][string]$Pdf,
    [Parameter(Mandatory = $true)][int]$Page,
    [Parameter(Mandatory = $true)][string]$Out,
    [double]$Scale = 2.0
)
# Render one page of a PDF to PNG with the built-in Windows.Data.Pdf (no install needed). Page starts at 1.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await($op, $resultType) {
    $m = $asTaskGeneric.MakeGenericMethod($resultType)
    $task = $m.Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
}

$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Pdf)) ([Windows.Storage.StorageFile])
$doc = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
if ($Page -lt 1 -or $Page -gt $doc.PageCount) { throw ('page out of range, total ' + $doc.PageCount) }
$pg = $doc.GetPage($Page - 1)
$opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
$opts.DestinationWidth = [uint32]($pg.Size.Width * $Scale)
$opts.DestinationHeight = [uint32]($pg.Size.Height * $Scale)
$ras = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    })[0]
$renderTask = $asTaskAction.Invoke($null, @($pg.RenderToStreamAsync($ras, $opts)))
$renderTask.Wait(-1) | Out-Null
$stream = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ras.GetInputStreamAt(0))
$fs = [System.IO.File]::Create($Out)
$stream.CopyTo($fs)
$fs.Close()
$stream.Close()
Write-Output ('pages=' + $doc.PageCount + ' size=' + [int]$pg.Size.Width + 'x' + [int]$pg.Size.Height + 'pt out=' + $Out)
