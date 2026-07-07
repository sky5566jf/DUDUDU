using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

class IconGenerator
{
    static void Main()
    {
        string sourcePath = @"F:\龙虾项目\TrollVNC\prefs\TrollVNCPrefs\Resources\icon@3x.png";
        string outputDir = @"F:\龙虾项目\TrollVNC\layout\usr\share\trollvnc\webclients\novnc\app\images\icons";
        
        int[] sizes = { 40, 58, 60, 80, 87, 120, 152, 167, 180 };
        
        using (Image sourceImage = Image.FromFile(sourcePath))
        {
            foreach (int size in sizes)
            {
                using (Bitmap resized = new Bitmap(size, size))
                {
                    using (Graphics g = Graphics.FromImage(resized))
                    {
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
                        g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                        g.CompositingQuality = System.Drawing.Drawing2D.CompositingQuality.HighQuality;
                        
                        g.DrawImage(sourceImage, 0, 0, size, size);
                    }
                    
                    string outputPath = Path.Combine(outputDir, $"novnc-ios-{size}.png");
                    resized.Save(outputPath, ImageFormat.Png);
                    Console.WriteLine($"Generated: {outputPath}");
                }
            }
        }
        
        Console.WriteLine("All icons generated successfully!");
    }
}
