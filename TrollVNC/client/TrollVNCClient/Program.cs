using System;
using System.Windows.Forms;

namespace TrollVNCClient;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}
