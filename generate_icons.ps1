Add-Type -AssemblyName System.Drawing

$sourcePath = "F:\龙虾项目\TrollVNC\prefs\TrollVNCPrefs\Resources\icon@3x.png"
$outputDir = "F:\龙虾项目\TrollVNC\layout\usr\share\trollvnc\webclients\novnc\app\images\icons"

$sizes = @(40, 58, 60, 80, 87, 120, 152, 167, 180)

$sourceImage = [System.Drawing.Image]::FromFile($sourcePath)

foreach ($size in $sizes) {
    $resized = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($resized)
    
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    
    $g.DrawImage($sourceImage, 0, 0, $size, $size)
    
    $outputPath = Join-Path $outputDir "novnc-ios-$size.png"
    $resized.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    
    $g.Dispose()
    $resized.Dispose()
    
    Write-Host "Generated: $outputPath"
}

$sourceImage.Dispose()
Write-Host "All icons generated successfully!"
