# DiskLens Premium V3
# Premium SSD-optimized disk analyzer with custom UI, inline branching tree and safe operations.
# Windows 10/11 - Windows PowerShell 5.1

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

$script:LogPath = Join-Path $PSScriptRoot "DiskLens_Hata.log"

function Write-BootstrapLog([string]$context, $exception) {
    try {
        $detail = "Bilinmeyen hata"
        if ($exception -and $exception.Message) { $detail = $exception.Message }
        $stack = ""
        try { if ($exception -and $exception.StackTrace) { $stack = $exception.StackTrace } } catch { }
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $context`r`n$detail`r`n$stack`r`n------------------------------`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $entry, [System.Text.Encoding]::UTF8)
    } catch { }
}

$script:app = [System.Windows.Application]::Current
if ($null -eq $script:app) {
    try {
        $script:app = New-Object System.Windows.Application
    }
    catch {
        Write-BootstrapLog "WPF uygulaması oluşturulamadı" $_.Exception
        [System.Windows.MessageBox]::Show(
            "DiskLens başlatılamadı.`n`n$($_.Exception.Message)`n`nAyrıntı: DiskLens_Hata.log",
            "DiskLens Premium V3.2.9.2",
            "OK",
            "Error"
        ) | Out-Null
        exit 1
    }
}

try {
    $script:app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
}
catch {
    Write-BootstrapLog "ShutdownMode ayarlanamadı" $_.Exception
    [System.Windows.MessageBox]::Show(
        "DiskLens başlatılırken WPF hatası oluştu.`n`n$($_.Exception.Message)`n`nAyrıntı: DiskLens_Hata.log",
        "DiskLens Premium V3.2.9.2",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

$engine = @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Linq;

namespace DiskLensPremiumV3
{
    public sealed class FileItem
    {
        public string Name { get; set; }
        public string ParentPath { get; set; }
        public string FullPath { get; set; }
        public string Extension { get; set; }
        public string Category { get; set; }
        public long Bytes { get; set; }
        public string SizeText { get; set; }
        public DateTime Modified { get; set; }
        public string ModifiedText { get; set; }
        public bool IsSystemLike { get; set; }
    }

    public sealed class FolderItem
    {
        public string Name { get; set; }
        public string ParentPath { get; set; }
        public string FullPath { get; set; }
        public long DirectBytes { get; set; }
        public long TotalBytes { get; set; }
        public long DirectFiles { get; set; }
        public string SizeText { get; set; }
        public string DirectSizeText { get; set; }
        public string FilesText { get; set; }
        public DateTime Modified { get; set; }
        public string ModifiedText { get; set; }
        public bool IsSystemLike { get; set; }
    }

    internal sealed class FolderAgg
    {
        public string Path;
        public string Parent;
        public long DirectBytes;
        public long DirectFiles;
        public DateTime Modified;
        public bool IsSystemLike;
    }

    public sealed class ScanProgress
    {
        public long Files { get; set; }
        public long Bytes { get; set; }
        public long Dirs { get; set; }
        public int Skipped { get; set; }
        public string CurrentFolder { get; set; }
        public string CurrentItem { get; set; }
        public long CurrentItemBytes { get; set; }
    }

    public sealed class ScanResult
    {
        public List<FileItem> Files { get; set; }
        public List<FolderItem> Folders { get; set; }
        public long FileCount { get; set; }
        public long TotalBytes { get; set; }
        public long DirCount { get; set; }
        public int Skipped { get; set; }
        public bool Cancelled { get; set; }
        public bool Truncated { get; set; }
        public long ElapsedMilliseconds { get; set; }
        public long MinFileBytes { get; set; }
        public int WorkerCount { get; set; }
        public string RootPath { get; set; }
    }

    public static class Scanner
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WIN32_FIND_DATA
        {
            public FileAttributes dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;
            public uint dwReserved0;
            public uint dwReserved1;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string cFileName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
            public string cAlternateFileName;
        }

        private enum FINDEX_INFO_LEVELS { FindExInfoStandard = 0, FindExInfoBasic = 1 }
        private enum FINDEX_SEARCH_OPS { FindExSearchNameMatch = 0, FindExSearchLimitToDirectories = 1, FindExSearchLimitToDevices = 2 }

        [Flags]
        private enum FIND_FIRST_EX_FLAGS : uint
        {
            NONE = 0,
            CASE_SENSITIVE = 1,
            LARGE_FETCH = 2
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileEx(
            string lpFileName,
            FINDEX_INFO_LEVELS fInfoLevelId,
            out WIN32_FIND_DATA lpFindFileData,
            FINDEX_SEARCH_OPS fSearchOp,
            IntPtr lpSearchFilter,
            FIND_FIRST_EX_FLAGS dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindNextFile(IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindClose(IntPtr hFindFile);

        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        private static readonly HashSet<string> VideoExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".mp4",".mkv",".avi",".mov",".wmv",".flv",".webm",".m4v",".mpeg",".mpg",".ts",".mts" };

        private static readonly HashSet<string> ArchiveExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".zip",".rar",".7z",".tar",".gz",".bz2",".xz",".iso",".cab",".vhd",".vhdx" };

        private static readonly HashSet<string> ImageExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".jpg",".jpeg",".png",".gif",".bmp",".tiff",".webp",".heic",".svg",".raw",".cr2",".nef",".psd" };

        private static readonly HashSet<string> AudioExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".mp3",".wav",".flac",".aac",".m4a",".ogg",".wma",".opus" };

        private static readonly HashSet<string> DocExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".pdf",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".txt",".rtf",".csv",".odt",".ods",".odp" };

        private static string CategoryOf(string ext)
        {
            if (String.IsNullOrEmpty(ext)) return "Diğer";
            if (VideoExt.Contains(ext)) return "Video";
            if (ArchiveExt.Contains(ext)) return "Arşiv";
            if (ImageExt.Contains(ext)) return "Görsel";
            if (AudioExt.Contains(ext)) return "Ses";
            if (DocExt.Contains(ext)) return "Belge";
            return "Diğer";
        }

        private static string AddLongPrefix(string path)
        {
            if (path.StartsWith(@"\\?\")) return path;
            if (path.StartsWith(@"\\"))
                return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        private static DateTime FileTimeToLocal(System.Runtime.InteropServices.ComTypes.FILETIME ft)
        {
            long high = (long)ft.dwHighDateTime;
            long fileTime = (high << 32) + (uint)ft.dwLowDateTime;
            if (fileTime <= 0) return DateTime.MinValue;
            try { return DateTime.FromFileTimeUtc(fileTime).ToLocalTime(); }
            catch { return DateTime.MinValue; }
        }

        private static string SafeParent(string path)
        {
            try
            {
                string trimmed = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return Path.GetDirectoryName(trimmed) ?? "";
            }
            catch { return ""; }
        }

        private static string SafeName(string path)
        {
            try
            {
                string trimmed = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string name = Path.GetFileName(trimmed);
                return String.IsNullOrEmpty(name) ? path : name;
            }
            catch { return path; }
        }

        private static bool IsSystemLikePath(string fullPath, bool attributeFlag)
        {
            if (attributeFlag) return true;
            try
            {
                string full = Path.GetFullPath(fullPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string[] roots = new string[] {
                    Environment.GetEnvironmentVariable("WINDIR"),
                    Environment.GetEnvironmentVariable("ProgramFiles"),
                    Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
                    Environment.GetEnvironmentVariable("ProgramData")
                };

                foreach (string r in roots)
                {
                    if (String.IsNullOrWhiteSpace(r)) continue;
                    string root = Path.GetFullPath(r).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    if (full.Equals(root, StringComparison.OrdinalIgnoreCase) ||
                        full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        return true;
                }
            }
            catch { }
            return false;
        }

        public static ScanResult Scan(
            string root,
            bool recursive,
            bool includeHiddenSystem,
            long minFileBytes,
            int maxListedFiles,
            int requestedWorkers,
            ConcurrentQueue<object> progressQueue,
            ManualResetEventSlim pauseGate,
            CancellationToken token)
        {
            var sw = Stopwatch.StartNew();
            int workers = Math.Max(1, Math.Min(requestedWorkers, 16));

            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (root.Length == 2 && root[1] == ':') root += Path.DirectorySeparatorChar;

            var folders = new ConcurrentDictionary<string, FolderAgg>(StringComparer.OrdinalIgnoreCase);
            DateTime rootModified = DateTime.MinValue;
            try { rootModified = Directory.GetLastWriteTime(root); } catch { }
            folders[root] = new FolderAgg {
                Path = root, Parent = SafeParent(root), DirectBytes = 0, DirectFiles = 0,
                Modified = rootModified, IsSystemLike = IsSystemLikePath(root, false)
            };

            var listedFiles = new ConcurrentBag<FileItem>();
            long listedCount = 0;
            int truncatedFlag = 0;

            long fileCount = 0;
            long totalBytes = 0;
            long dirCount = 0;
            int skipped = 0;

            var work = new BlockingCollection<string>(new ConcurrentQueue<string>());
            long pending = 1;
            work.Add(root);

            using (token.Register(() =>
            {
                try { pauseGate.Set(); } catch { }
                try { work.CompleteAdding(); } catch { }
            }))
            {
                Task[] tasks = new Task[workers];

                for (int w = 0; w < workers; w++)
                {
                    tasks[w] = Task.Factory.StartNew(() =>
                    {
                        try
                        {
                            foreach (string dir in work.GetConsumingEnumerable())
                            {
                                if (token.IsCancellationRequested)
                                {
                                    if (Interlocked.Decrement(ref pending) == 0)
                                        work.CompleteAdding();
                                    continue;
                                }

                                pauseGate.Wait(token);
                                Interlocked.Increment(ref dirCount);

                                FolderAgg agg = folders.GetOrAdd(dir, p => new FolderAgg {
                                    Path = p, Parent = SafeParent(p), DirectBytes = 0, DirectFiles = 0,
                                    Modified = DateTime.MinValue, IsSystemLike = IsSystemLikePath(p, false)
                                });

                                string search = AddLongPrefix(Path.Combine(dir, "*"));
                                WIN32_FIND_DATA data;
                                IntPtr handle = FindFirstFileEx(
                                    search,
                                    FINDEX_INFO_LEVELS.FindExInfoBasic,
                                    out data,
                                    FINDEX_SEARCH_OPS.FindExSearchNameMatch,
                                    IntPtr.Zero,
                                    FIND_FIRST_EX_FLAGS.LARGE_FETCH);

                                if (handle == INVALID_HANDLE_VALUE)
                                {
                                    Interlocked.Increment(ref skipped);
                                    if (Interlocked.Decrement(ref pending) == 0)
                                        work.CompleteAdding();
                                    continue;
                                }

                                try
                                {
                                    int localCounter = 0;

                                    do
                                    {
                                        if (token.IsCancellationRequested) break;

                                        if ((localCounter++ & 255) == 0)
                                            pauseGate.Wait(token);

                                        string name = data.cFileName;
                                        if (name == "." || name == "..") continue;

                                        bool isDir = (data.dwFileAttributes & FileAttributes.Directory) != 0;
                                        bool isReparse = (data.dwFileAttributes & FileAttributes.ReparsePoint) != 0;
                                        bool isHiddenOrSystem =
                                            (data.dwFileAttributes & (FileAttributes.Hidden | FileAttributes.System)) != 0;

                                        string full = Path.Combine(dir, name);

                                        if (isDir)
                                        {
                                            if (!recursive || isReparse) continue;
                                            if (!includeHiddenSystem && isHiddenOrSystem) continue;

                                            folders.TryAdd(full, new FolderAgg {
                                                Path = full,
                                                Parent = dir,
                                                DirectBytes = 0,
                                                DirectFiles = 0,
                                                Modified = FileTimeToLocal(data.ftLastWriteTime),
                                                IsSystemLike = IsSystemLikePath(full, isHiddenOrSystem)
                                            });

                                            Interlocked.Increment(ref pending);
                                            try
                                            {
                                                if (!work.IsAddingCompleted) work.Add(full);
                                                else Interlocked.Decrement(ref pending);
                                            }
                                            catch (InvalidOperationException)
                                            {
                                                Interlocked.Decrement(ref pending);
                                            }

                                            continue;
                                        }

                                        if (!includeHiddenSystem && isHiddenOrSystem) continue;

                                        long size = ((long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
                                        long fc = Interlocked.Increment(ref fileCount);
                                        Interlocked.Add(ref totalBytes, size);
                                        Interlocked.Add(ref agg.DirectBytes, size);
                                        Interlocked.Increment(ref agg.DirectFiles);

                                        if (size >= minFileBytes)
                                        {
                                            long slot = Interlocked.Increment(ref listedCount);
                                            if (slot <= maxListedFiles)
                                            {
                                                string ext = "";
                                                try { ext = Path.GetExtension(name) ?? ""; } catch { }

                                                DateTime modified = FileTimeToLocal(data.ftLastWriteTime);

                                                listedFiles.Add(new FileItem {
                                                    Name = name,
                                                    ParentPath = dir,
                                                    FullPath = full,
                                                    Extension = String.IsNullOrEmpty(ext) ? "—" : ext,
                                                    Category = CategoryOf(ext),
                                                    Bytes = size,
                                                    SizeText = FormatBytes(size),
                                                    Modified = modified,
                                                    ModifiedText = modified == DateTime.MinValue ? "—" : modified.ToString("dd.MM.yyyy HH:mm"),
                                                    IsSystemLike = IsSystemLikePath(full, isHiddenOrSystem)
                                                });
                                            }
                                            else
                                            {
                                                Interlocked.Exchange(ref truncatedFlag, 1);
                                            }
                                        }

                                        // UI'yi boğmadan canlı öğe bilgisi üret.
                                        // Her 512 dosyada bir güncelleme: hızlı SSD taramasında yeterince akıcı,
                                        // fakat UI thread'ine binlerce olay göndermez.
                                        if ((fc & 511) == 0)
                                        {
                                            progressQueue.Enqueue(new ScanProgress {
                                                Files = fc,
                                                Bytes = Interlocked.Read(ref totalBytes),
                                                Dirs = Interlocked.Read(ref dirCount),
                                                Skipped = Volatile.Read(ref skipped),
                                                CurrentFolder = dir,
                                                CurrentItem = full,
                                                CurrentItemBytes = size
                                            });
                                        }

                                    } while (FindNextFile(handle, out data));
                                }
                                catch (OperationCanceledException) { }
                                catch
                                {
                                    Interlocked.Increment(ref skipped);
                                }
                                finally
                                {
                                    FindClose(handle);
                                }

                                if (Interlocked.Decrement(ref pending) == 0)
                                    work.CompleteAdding();
                            }
                        }
                        catch (OperationCanceledException) { }
                        catch (InvalidOperationException) { }
                    }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                }

                try { Task.WaitAll(tasks); }
                catch { }
            }

            var aggs = folders.Values.ToList();
            var totals = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);

            foreach (var f in aggs)
                totals[f.Path] = Interlocked.Read(ref f.DirectBytes);

            foreach (var f in aggs.OrderByDescending(x => x.Path.Length))
            {
                long value = 0;
                totals.TryGetValue(f.Path, out value);

                if (!String.IsNullOrEmpty(f.Parent) && totals.ContainsKey(f.Parent))
                    totals[f.Parent] = totals[f.Parent] + value;
            }

            var folderItems = new List<FolderItem>(aggs.Count);
            foreach (var f in aggs)
            {
                long total = 0;
                totals.TryGetValue(f.Path, out total);

                long direct = Interlocked.Read(ref f.DirectBytes);
                long directFiles = Interlocked.Read(ref f.DirectFiles);

                folderItems.Add(new FolderItem {
                    Name = SafeName(f.Path),
                    ParentPath = f.Parent ?? "",
                    FullPath = f.Path,
                    DirectBytes = direct,
                    TotalBytes = total,
                    DirectFiles = directFiles,
                    SizeText = FormatBytes(total),
                    DirectSizeText = FormatBytes(direct),
                    FilesText = directFiles.ToString("N0"),
                    Modified = f.Modified,
                    ModifiedText = f.Modified == DateTime.MinValue ? "—" : f.Modified.ToString("dd.MM.yyyy HH:mm"),
                    IsSystemLike = f.IsSystemLike
                });
            }

            sw.Stop();

            return new ScanResult {
                Files = listedFiles.ToList(),
                Folders = folderItems,
                FileCount = Interlocked.Read(ref fileCount),
                TotalBytes = Interlocked.Read(ref totalBytes),
                DirCount = Interlocked.Read(ref dirCount),
                Skipped = Volatile.Read(ref skipped),
                Cancelled = token.IsCancellationRequested,
                Truncated = Volatile.Read(ref truncatedFlag) != 0,
                ElapsedMilliseconds = sw.ElapsedMilliseconds,
                MinFileBytes = minFileBytes,
                WorkerCount = workers,
                RootPath = root
            };
        }

        public static string FormatBytes(long bytes)
        {
            const double KB = 1024.0;
            const double MB = 1024.0 * 1024.0;
            const double GB = 1024.0 * 1024.0 * 1024.0;
            const double TB = 1024.0 * 1024.0 * 1024.0 * 1024.0;

            if (bytes >= TB) return (bytes / TB).ToString("N2") + " TB";
            if (bytes >= GB) return (bytes / GB).ToString("N2") + " GB";
            if (bytes >= MB) return (bytes / MB).ToString("N2") + " MB";
            if (bytes >= KB) return (bytes / KB).ToString("N2") + " KB";
            return bytes.ToString("N0") + " B";
        }
    }
}
"@

try {
    Add-Type -TypeDefinition $engine -Language CSharp -ErrorAction Stop
}
catch {
    Write-BootstrapLog "Tarama motoru başlatılamadı" $_.Exception
    [System.Windows.MessageBox]::Show(
        "Tarama motoru başlatılamadı.`n`n$($_.Exception.Message)`n`nAyrıntı: DiskLens_Hata.log",
        "DiskLens Premium V3.2.9",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="DiskLens Premium V3.2.9"
    Width="1520"
    Height="940"
    MinWidth="1180"
    MinHeight="760"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    ResizeMode="CanResize"
    Background="{DynamicResource WinBg}"
    FontFamily="Segoe UI"
    FontSize="13">

    <Window.Resources>
        <SolidColorBrush x:Key="WinBg" Color="#F6F8FB"/>
        <SolidColorBrush x:Key="Panel" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="PanelAlt" Color="#F8FAFC"/>
        <SolidColorBrush x:Key="SidebarBg" Color="#111827"/>
        <SolidColorBrush x:Key="SidebarCard" Color="#182334"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#0F172A"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#64748B"/>
        <SolidColorBrush x:Key="TextOnDark" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrushFlat" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="Accent" Color="#5B4CFF"/>
        <SolidColorBrush x:Key="Accent2" Color="#8478FF"/>
        <SolidColorBrush x:Key="AccentSoft" Color="#EEEAFE"/>
        <SolidColorBrush x:Key="Success" Color="#16A34A"/>
        <SolidColorBrush x:Key="Warning" Color="#D97706"/>
        <SolidColorBrush x:Key="Danger" Color="#E11D48"/>
        <SolidColorBrush x:Key="DangerSoft" Color="#FFF1F2"/>
        <SolidColorBrush x:Key="MiniBarTrack" Color="#E9EEF5"/>
        <SolidColorBrush x:Key="TitleBtnHover" Color="#EEF2F7"/>

        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource Panel}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrushFlat}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="18"/>
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="{DynamicResource Accent}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="12">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="{DynamicResource Accent2}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bg" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bg" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FlatButton" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Background" Value="{DynamicResource PanelAlt}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="12">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="{DynamicResource AccentSoft}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bg" Property="Opacity" Value="0.82"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bg" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource FlatButton}">
            <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
            <Setter Property="Background" Value="{DynamicResource DangerSoft}"/>
        </Style>

        <Style x:Key="IconTitleButton" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Width" Value="38"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="{DynamicResource TitleBtnHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bg" Property="Opacity" Value="0.82"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Height" Value="40"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Background" Value="{DynamicResource Panel}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrushFlat}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBg" Background="{TemplateBinding Background}" CornerRadius="7" Margin="3,1">
                            <ContentPresenter Margin="6,2"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBg" Property="Background" Value="{DynamicResource AccentSoft}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItemBg" Property="Background" Value="{DynamicResource AccentSoft}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Height" Value="32"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Background" Value="{DynamicResource Panel}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrushFlat}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="Outer" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="26"/>
                                    </Grid.ColumnDefinitions>
                                    <ContentPresenter Margin="10,0,4,0" VerticalAlignment="Center" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                                    <Path Grid.Column="1" Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Grid>
                            </Border>
                            <ToggleButton Focusable="False" Background="Transparent" BorderThickness="0" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" PopupAnimation="Fade" Focusable="False">
                                <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource BorderBrushFlat}" BorderThickness="1" CornerRadius="10" Padding="3" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" Margin="0,4,0,0">
                                    <ScrollViewer MaxHeight="280" CanContentScroll="True"><ItemsPresenter/></ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Outer" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Outer" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Outer" Property="Opacity" Value="0.45"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TreeView">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        </Style>

        <Style TargetType="TreeViewItem">
            <Setter Property="Margin" Value="0,1,0,1"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="IsExpanded" Value="False"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TreeViewItem">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <ToggleButton x:Name="Expander" Grid.Column="0" Width="16" Height="28" Focusable="False" IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{DynamicResource TextSecondary}" Background="Transparent" BorderThickness="0" Content="›" FontSize="17">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="Transparent" CornerRadius="6">
                                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Grid.Column="1" ContentSource="Header" HorizontalAlignment="Stretch"/>
                            <ItemsPresenter x:Name="ItemsHost" Grid.Row="1" Grid.Column="1" Visibility="Collapsed"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="HasItems" Value="False"><Setter TargetName="Expander" Property="Visibility" Value="Hidden"/></Trigger>
                            <Trigger Property="IsExpanded" Value="True"><Setter TargetName="ItemsHost" Property="Visibility" Value="Visible"/><Setter TargetName="Expander" Property="Content" Value="⌄"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="56"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Custom premium title bar -->
        <Border Grid.Row="0" Background="{DynamicResource WinBg}" BorderBrush="{DynamicResource BorderBrushFlat}" BorderThickness="0,0,0,1">
            <Grid x:Name="TitleBarGrid" Margin="14,8,12,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Grid Width="38" Height="38" Margin="0,0,10,0">
                        <Ellipse Fill="{DynamicResource Accent}" Width="38" Height="38"/>
                        <Ellipse Fill="#FFFFFF" Width="14" Height="14" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="6,7,0,0" Opacity="0.92"/>
                        <Ellipse Fill="#FFFFFF" Width="12" Height="12" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,7,7" Opacity="0.76"/>
                    </Grid>
                    <StackPanel>
                        <TextBlock Text="DiskLens" Foreground="{DynamicResource TextPrimary}" FontSize="18" FontWeight="Bold"/>
                        <TextBlock Text="Premium V3.2.9" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                    </StackPanel>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="ThemeButton" Style="{StaticResource IconTitleButton}" ToolTip="Tema değiştir" Content="☾" Margin="0,0,6,0"/>
                    <Button x:Name="MinButton" Style="{StaticResource IconTitleButton}" Content="—" Margin="0,0,6,0"/>
                    <Button x:Name="MaxButton" Style="{StaticResource IconTitleButton}" Content="▢" Margin="0,0,6,0"/>
                    <Button x:Name="CloseButton" Style="{StaticResource IconTitleButton}" Content="✕"/>
                </StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="270"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border x:Name="ToastBorder" Grid.ColumnSpan="2" Panel.ZIndex="200" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,16,20,0" MinWidth="330" MaxWidth="520" Background="#1F2937" CornerRadius="14" Padding="14,11" BorderBrush="#334155" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Ellipse x:Name="ToastDot" Width="9" Height="9" Fill="#60A5FA" Margin="0,3,10,0" VerticalAlignment="Top"/>
                    <TextBlock x:Name="ToastText" Grid.Column="1" Text="Bildirim" Foreground="White" TextWrapping="Wrap"/>
                </Grid>
            </Border>

            <!-- Sidebar -->
            <Border Grid.Column="0" Background="{DynamicResource SidebarBg}">
                <Grid Margin="20">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Margin="0,4,0,18">
                        <TextBlock Text="Klasör alan haritası" Foreground="{DynamicResource TextOnDark}" FontWeight="Bold" FontSize="20"/>
                        <TextBlock Text="Ana odak: büyükten küçüğe dallanarak ilerleyen klasör görünümü." Foreground="#96A3B7" TextWrapping="Wrap" Margin="0,7,0,0"/>
                    </StackPanel>

                    <Border Grid.Row="1" Background="{DynamicResource SidebarCard}" CornerRadius="16" Padding="14">
                        <StackPanel>
                            <TextBlock Text="KONUM" Foreground="#8293AE" FontSize="10" FontWeight="Bold" Margin="0,0,0,9"/>
                            <Button x:Name="DriveButton" Content="Disk seç" Style="{StaticResource PrimaryButton}" HorizontalContentAlignment="Left" Margin="0,0,0,8"/>
                            <Button x:Name="FolderButton" Content="Klasör seç" Style="{StaticResource FlatButton}" HorizontalContentAlignment="Left"/>
                            <TextBlock x:Name="SidePath" Text="—" Foreground="White" Margin="0,12,0,0" TextWrapping="Wrap" MaxHeight="54"/>
                        </StackPanel>
                    </Border>

                    <Border Grid.Row="2" Background="{DynamicResource SidebarCard}" CornerRadius="16" Padding="14" Margin="0,14,0,0">
                        <StackPanel>
                            <TextBlock Text="TARAMA AYARLARI" Foreground="#8293AE" FontSize="10" FontWeight="Bold" Margin="0,0,0,9"/>
                            <TextBlock Text="Min. dosya boyutu" Foreground="White" FontSize="11" Margin="0,0,0,4"/>
                            <ComboBox x:Name="MinSizeBox" SelectedIndex="2">
                                <ComboBoxItem Content="Tümü" Tag="0"/>
                                <ComboBoxItem Content="1 MB +" Tag="1048576"/>
                                <ComboBoxItem Content="10 MB +" Tag="10485760"/>
                                <ComboBoxItem Content="100 MB +" Tag="104857600"/>
                                <ComboBoxItem Content="500 MB +" Tag="524288000"/>
                                <ComboBoxItem Content="1 GB +" Tag="1073741824"/>
                                <ComboBoxItem Content="5 GB +" Tag="5368709120"/>
                            </ComboBox>

                            <TextBlock Text="Tarama modu" Foreground="White" FontSize="11" Margin="0,10,0,4"/>
                            <ComboBox x:Name="WorkerBox" SelectedIndex="2">
                                <ComboBoxItem Content="Dengeli" Tag="4"/>
                                <ComboBoxItem Content="Çok hızlı" Tag="8"/>
                                <ComboBoxItem Content="Maksimum (SSD)" Tag="12"/>
                            </ComboBox>

                            <TextBlock Text="Liste limiti" Foreground="White" FontSize="11" Margin="0,10,0,4"/>
                            <ComboBox x:Name="LimitBox" SelectedIndex="1">
                                <ComboBoxItem Content="100.000" Tag="100000"/>
                                <ComboBoxItem Content="250.000" Tag="250000"/>
                                <ComboBoxItem Content="500.000" Tag="500000"/>
                            </ComboBox>

                            <CheckBox x:Name="RecursiveCheck" Content="Alt klasörler" IsChecked="True" Foreground="White" Margin="0,12,0,4"/>
                            <CheckBox x:Name="HiddenCheck" Content="Sistem / gizli dahil" IsChecked="True" Foreground="White"/>

                            <Grid Margin="0,14,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Button x:Name="ScanButton" Grid.Column="0" Content="Hızlı tara" Style="{StaticResource PrimaryButton}"/>
                                <Button x:Name="RefreshButton" Grid.Column="2" Content="Yenile" Style="{StaticResource FlatButton}" IsEnabled="False"/>
                            </Grid>
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Button x:Name="PauseButton" Grid.Column="0" Content="Duraklat" Style="{StaticResource FlatButton}" IsEnabled="False"/>
                                <Button x:Name="CancelButton" Grid.Column="2" Content="İptal" Style="{StaticResource FlatButton}" IsEnabled="False"/>
                            </Grid>
                        </StackPanel>
                    </Border>

                    <Border Grid.Row="3" Background="{DynamicResource SidebarCard}" CornerRadius="16" Padding="14" Margin="0,14,0,0">
                        <StackPanel>
                            <TextBlock Text="SEÇİLİ ÖĞE" Foreground="#8293AE" FontSize="10" FontWeight="Bold" Margin="0,0,0,9"/>
                            <TextBlock x:Name="SelectedItemText" Text="Henüz seçim yok" Foreground="White" TextWrapping="Wrap"/>
                            <TextBlock x:Name="SelectedItemMeta" Text="—" Foreground="#96A3B7" TextWrapping="Wrap" Margin="0,7,0,0"/>
                            <UniformGrid Columns="5" Margin="0,12,0,0">
                                <Button x:Name="OpenButton"
                                        Style="{StaticResource FlatButton}"
                                        Height="40" Padding="0"
                                        Margin="0,0,5,0"
                                        ToolTip="Konumu aç"
                                        IsEnabled="False">
                                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="17"/>
                                </Button>
                                <Button x:Name="RenameButton"
                                        Style="{StaticResource FlatButton}"
                                        Height="40" Padding="0"
                                        Margin="0,0,5,0"
                                        ToolTip="Yeniden adlandır"
                                        IsEnabled="False">
                                    <TextBlock Text="&#xE70F;" FontFamily="Segoe MDL2 Assets" FontSize="17"/>
                                </Button>
                                <Button x:Name="MoveButton"
                                        Style="{StaticResource FlatButton}"
                                        Height="40" Padding="0"
                                        Margin="0,0,5,0"
                                        ToolTip="Taşı"
                                        IsEnabled="False">
                                    <TextBlock Text="&#xE8DE;" FontFamily="Segoe MDL2 Assets" FontSize="17"/>
                                </Button>
                                <Button x:Name="SelectedRefreshButton"
                                        Style="{StaticResource FlatButton}"
                                        Height="40" Padding="0"
                                        Margin="0,0,5,0"
                                        ToolTip="Sadece seçili öğeyi tekrar tara"
                                        IsEnabled="False">
                                    <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="17"/>
                                </Button>
                                <Button x:Name="DeleteButton"
                                        Style="{StaticResource DangerButton}"
                                        Height="40" Padding="0"
                                        ToolTip="Sil"
                                        IsEnabled="False">
                                    <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" FontSize="17"/>
                                </Button>
                            </UniformGrid>
                        </StackPanel>
                    </Border>

                    <TextBlock Grid.Row="4" Text="⚡ SSD optimizasyonu: Native Win32 tarama, paralel işçiler, lazy tree yükleme, minimum boyut filtresi ve seyrek UI güncellemesi kullanılır."
                               Foreground="#96A3B7" TextWrapping="Wrap" FontSize="11" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
                </Grid>
            </Border>

            <!-- Main content -->
            <Grid Grid.Column="1" Margin="22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Disk usage -->
                <Border Grid.Row="0" Style="{StaticResource CardStyle}" Padding="18" Margin="0,0,0,14">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="Disk doluluğu" FontSize="19" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                                <TextBlock x:Name="UsageSubtitle" Text="Disk veya klasör seçtikten sonra kullanım grafiği burada görünür." Foreground="{DynamicResource TextSecondary}" Margin="0,4,0,0"/>
                            </StackPanel>
                            <TextBlock x:Name="UsagePercent" Grid.Column="1" Text="—" Foreground="{DynamicResource Accent}" FontWeight="Bold" FontSize="28" VerticalAlignment="Center"/>
                        </Grid>

                        <Border x:Name="UsageTrack" Grid.Row="1" Height="20" Background="{DynamicResource MiniBarTrack}" CornerRadius="10" Margin="0,16,0,14" ClipToBounds="True">
                            <Border x:Name="UsageFill" HorizontalAlignment="Left" Width="0" Background="{DynamicResource Accent}" CornerRadius="10"/>
                        </Border>

                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="KULLANILAN" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10"/>
                                <TextBlock x:Name="UsedSpaceChart" Text="—" Foreground="{DynamicResource TextPrimary}" FontWeight="SemiBold" FontSize="16" Margin="0,5,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1">
                                <TextBlock Text="BOŞ" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10"/>
                                <TextBlock x:Name="FreeSpaceChart" Text="—" Foreground="{DynamicResource TextPrimary}" FontWeight="SemiBold" FontSize="16" Margin="0,5,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="2">
                                <TextBlock Text="TOPLAM" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10"/>
                                <TextBlock x:Name="TotalSpaceChart" Text="—" Foreground="{DynamicResource TextPrimary}" FontWeight="SemiBold" FontSize="16" Margin="0,5,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="3">
                                <TextBlock Text="DOSYA / KLASÖR / SÜRE" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10"/>
                                <TextBlock x:Name="SummaryStat" Text="0 / 0 / —" Foreground="{DynamicResource TextPrimary}" FontWeight="SemiBold" FontSize="16" Margin="0,5,0,0"/>
                            </StackPanel>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Controls above map -->
                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="230"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="SearchBox" Grid.Column="0" Height="34" ToolTip="Klasör veya dosya adı ara"/>
                    <TextBlock Grid.Column="1" Text="Her zaman büyükten küçüğe sıralı • klasör ve dosyalar aynı dallanma yapısında"
                               Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                </Grid>

                <!-- Live scan status -->
                <Border x:Name="LiveScanPanel"
                        Grid.Row="2"
                        Style="{StaticResource CardStyle}"
                        Padding="14"
                        Margin="0,0,0,12"
                        Visibility="Collapsed">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="290"/>
                        </Grid.ColumnDefinitions>

                        <Border Width="42" Height="42"
                                CornerRadius="12"
                                Background="{DynamicResource AccentSoft}"
                                VerticalAlignment="Top"
                                Margin="0,0,12,0">
                            <TextBlock x:Name="LiveScanSpinner"
                                       Text="◐"
                                       FontSize="21"
                                       Foreground="{DynamicResource Accent}"
                                       HorizontalAlignment="Center"
                                       VerticalAlignment="Center"/>
                        </Border>

                        <StackPanel Grid.Column="1">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="Taranıyor"
                                           FontWeight="Bold"
                                           FontSize="14"
                                           Foreground="{DynamicResource TextPrimary}"/>
                                <TextBlock x:Name="LiveScanStats"
                                           Text="0 dosya • 0 klasör"
                                           Foreground="{DynamicResource TextSecondary}"
                                           Margin="10,1,0,0"/>
                            </StackPanel>
                            <TextBlock x:Name="LiveScanCurrentText"
                                       Text="Tarama hazırlanıyor…"
                                       FontWeight="SemiBold"
                                       Foreground="{DynamicResource TextPrimary}"
                                       Margin="0,5,0,0"
                                       TextTrimming="CharacterEllipsis"
                                       ToolTip=""/>
                            <TextBlock Text="Tarama sürerken mevcut klasör ağacını görüntüleyebilir ve dalları açabilirsiniz. Sil / taşı / yeniden adlandır işlemleri sonuç uygulanana kadar güvenlik için kapalıdır."
                                       Foreground="{DynamicResource TextSecondary}"
                                       FontSize="10"
                                       TextWrapping="Wrap"
                                       Margin="0,4,12,0"/>
                            <ProgressBar x:Name="LiveScanProgress"
                                         Height="4"
                                         IsIndeterminate="True"
                                         Margin="0,9,16,0"/>
                        </StackPanel>

                        <Border Grid.Column="2"
                                Background="{DynamicResource PanelAlt}"
                                BorderBrush="{DynamicResource BorderBrushFlat}"
                                BorderThickness="1"
                                CornerRadius="12"
                                Padding="10">
                            <StackPanel>
                                <TextBlock Text="SON TARANANLAR"
                                           FontSize="9"
                                           FontWeight="Bold"
                                           Foreground="{DynamicResource TextSecondary}"
                                           Margin="0,0,0,5"/>
                                <StackPanel x:Name="LiveRecentStack"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- Main tree -->
                <Border Grid.Row="3" Style="{StaticResource CardStyle}">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <Grid Margin="18,16,18,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="120"/>
                                <ColumnDefinition Width="128"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="Klasör alan haritası" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
                            <TextBlock Grid.Column="1" Text="TOPLAM BOYUT" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Right"/>
                            <TextBlock Grid.Column="2" Text="ALAN ORANI" Foreground="{DynamicResource TextSecondary}" FontWeight="Bold" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Right"/>
                        </Grid>

                        <TreeView x:Name="FolderTree" Grid.Row="1" Margin="10,0,10,10"
                                  VirtualizingStackPanel.IsVirtualizing="True"
                                  VirtualizingStackPanel.VirtualizationMode="Recycling"
                                  ScrollViewer.CanContentScroll="True"/>
                    </Grid>
                </Border>

                <!-- status -->
                <Grid Grid.Row="4" Margin="6,12,6,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="{DynamicResource TextSecondary}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="StatusText" Text="Hazır" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                    <TextBlock x:Name="SkippedText" Grid.Column="1" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
                </Grid>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    "TitleBarGrid","ThemeButton","MinButton","MaxButton","CloseButton",
    "DriveButton","FolderButton","SidePath","MinSizeBox","WorkerBox","LimitBox","RecursiveCheck","HiddenCheck",
    "ScanButton","RefreshButton","PauseButton","CancelButton",
    "SelectedItemText","SelectedItemMeta","OpenButton","RenameButton","MoveButton","SelectedRefreshButton","DeleteButton",
    "UsageTrack","UsageFill","UsageSubtitle","UsagePercent","UsedSpaceChart","FreeSpaceChart","TotalSpaceChart","SummaryStat",
    "SearchBox","LiveScanPanel","LiveScanSpinner","LiveScanStats","LiveScanCurrentText","LiveScanProgress","LiveRecentStack",
    "FolderTree","StatusDot","StatusText","SkippedText","ToastBorder","ToastDot","ToastText"
)

foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value ($window.FindName($name)) -Scope Script
}

$script:isDark = $false
$script:selectedPath = $null
$script:rootPath = $null
$script:allFiles = @()
$script:allFolders = @()
$script:folderByPath = @{}
$script:childrenByParent = @{}
$script:filesByParent = @{}
$script:selectedNode = $null

$script:scanPS = $null
$script:scanRunspace = $null
$script:scanAsync = $null
$script:scanCts = $null
$script:pauseGate = $null
$script:progressQueue = $null
$script:isScanning = $false
$script:isPaused = $false
$script:isApplyingScanResult = $false
$script:scanSpinnerIndex = 0
$script:scanSpinnerFrames = @("◐","◓","◑","◒")

$script:isSelectedScanning = $false
$script:selectedScanPS = $null
$script:selectedScanRunspace = $null
$script:selectedScanAsync = $null
$script:selectedScanCts = $null
$script:selectedScanPause = $null
$script:selectedScanQueue = $null
$script:selectedScanTarget = $null
$script:selectedScanExpandedPaths = @()


function Theme-Color([string]$light, [string]$dark) {
    if ($script:isDark) { return $dark }
    return $light
}


function Apply-AppFont {
    try {
        $inter = [System.Windows.Media.Fonts]::SystemFontFamilies |
            Where-Object { $_.Source -eq "Inter" } |
            Select-Object -First 1

        if ($inter) {
            $window.FontFamily = $inter
            Set-Status "Inter yazı tipi etkin." "#16A34A"
        }
        else {
            $window.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        }
    }
    catch {
        try {
            $window.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        } catch { }
        try { Write-ErrorLog "Yazı tipi uygulanamadı" $_.Exception } catch { }
    }
}

function Set-BrushValue([string]$key, [string]$hex) {
    $window.Resources[$key] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

function Apply-Theme([bool]$darkMode) {
    if ($darkMode) {
        Set-BrushValue "WinBg" "#0B1220"
        Set-BrushValue "Panel" "#111827"
        Set-BrushValue "PanelAlt" "#162132"
        Set-BrushValue "SidebarBg" "#070B14"
        Set-BrushValue "SidebarCard" "#111827"
        Set-BrushValue "TextPrimary" "#F8FAFC"
        Set-BrushValue "TextSecondary" "#94A3B8"
        Set-BrushValue "TextOnDark" "#FFFFFF"
        Set-BrushValue "BorderBrushFlat" "#243041"
        Set-BrushValue "Accent" "#7C6BFF"
        Set-BrushValue "Accent2" "#9A8FFF"
        Set-BrushValue "AccentSoft" "#1A2555"
        Set-BrushValue "MiniBarTrack" "#223048"
        Set-BrushValue "TitleBtnHover" "#142033"
        Set-BrushValue "DangerSoft" "#3E1220"
        $ThemeButton.Content = "☀"
    } else {
        Set-BrushValue "WinBg" "#F6F8FB"
        Set-BrushValue "Panel" "#FFFFFF"
        Set-BrushValue "PanelAlt" "#F8FAFC"
        Set-BrushValue "SidebarBg" "#111827"
        Set-BrushValue "SidebarCard" "#182334"
        Set-BrushValue "TextPrimary" "#0F172A"
        Set-BrushValue "TextSecondary" "#64748B"
        Set-BrushValue "TextOnDark" "#FFFFFF"
        Set-BrushValue "BorderBrushFlat" "#E2E8F0"
        Set-BrushValue "Accent" "#5B4CFF"
        Set-BrushValue "Accent2" "#8478FF"
        Set-BrushValue "AccentSoft" "#EEEAFE"
        Set-BrushValue "MiniBarTrack" "#E9EEF5"
        Set-BrushValue "TitleBtnHover" "#EEF2F7"
        Set-BrushValue "DangerSoft" "#FFF1F2"
        $ThemeButton.Content = "☾"
    }
}

$toastTimer = New-Object System.Windows.Threading.DispatcherTimer
$toastTimer.Interval = [TimeSpan]::FromSeconds(5)
$toastTimer.Add_Tick({
    $toastTimer.Stop()
    $ToastBorder.Visibility = [System.Windows.Visibility]::Collapsed
})

function Show-Notification([string]$message, [string]$kind = "info") {
    try {
        $ToastText.Text = $message
        switch ($kind) {
            "error" { $ToastBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#4A1721"); $ToastDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FB7185") }
            "success" { $ToastBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#10392D"); $ToastDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#34D399") }
            "warning" { $ToastBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#4A3213"); $ToastDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FBBF24") }
            default { $ToastBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1F2937"); $ToastDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#60A5FA") }
        }
        $ToastBorder.Visibility = [System.Windows.Visibility]::Visible
        $toastTimer.Stop(); $toastTimer.Start()
    } catch { }
}

function Write-ErrorLog([string]$context, $exception) {
    try {
        $detail = "Bilinmeyen hata"
        if ($exception -and $exception.Message) { $detail = $exception.Message }

        $typeName = ""
        try { if ($exception) { $typeName = $exception.GetType().FullName } } catch { }

        $stack = ""
        try { if ($exception -and $exception.StackTrace) { $stack = $exception.StackTrace } } catch { }

        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $context`r`nTür: $typeName`r`nMesaj: $detail`r`n$stack`r`n------------------------------`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $entry, [System.Text.Encoding]::UTF8)
    }
    catch { }
}

function Show-AppError([string]$context, $exception, [string]$rawDetail = "") {
    $detail = "Bilinmeyen hata"
    try { if ($exception -and $exception.Message) { $detail = $exception.Message } } catch { }

    if (-not [string]::IsNullOrWhiteSpace($rawDetail)) {
        $detail = $rawDetail.Trim()
    }

    Write-ErrorLog $context $exception
    if (-not [string]::IsNullOrWhiteSpace($rawDetail)) {
        try {
            $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $context - PowerShell hata akışı`r`n$rawDetail`r`n------------------------------`r`n"
            [System.IO.File]::AppendAllText($script:LogPath, $entry, [System.Text.Encoding]::UTF8)
        } catch { }
    }

    $short = $detail
    if ($short.Length -gt 240) { $short = $short.Substring(0,240) + "…" }

    $msg = "$context — $short"
    Set-Status $msg "#E11D48"
    Show-Notification ($msg + "  •  Detay panoya kopyalandı.") "error"

    # Log dosyası boş veya erişilemez olsa bile hata kullanıcıdan kaybolmasın.
    try {
        [System.Windows.Clipboard]::SetText("$context`r`n`r`n$detail")
    } catch { }

    [System.Windows.MessageBox]::Show(
        "$context`n`n$detail`n`nHata ayrıntısı panoya da kopyalandı.",
        "DiskLens hata ayrıntısı",
        "OK",
        "Error"
    ) | Out-Null
}

function Set-Status([string]$text, [string]$color = "#64748B") {
    $StatusText.Text = $text
    $StatusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Format-Time([long]$ms) {
    if ($ms -lt 1000) { return "$ms ms" }
    if ($ms -lt 60000) { return ("{0:N1} sn" -f ($ms / 1000.0)) }
    return ([TimeSpan]::FromMilliseconds($ms)).ToString("mm\:ss")
}

function Get-DriveInfoFor([string]$path) {
    try {
        $root = [System.IO.Path]::GetPathRoot($path)
        if ($root) { return New-Object -TypeName System.IO.DriveInfo -ArgumentList $root }
    } catch {}
    return $null
}

function Is-DriveRoot([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $true }
    try {
        $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not $root) { return $false }
        return $full.Equals($root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Is-ProtectedPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $true }

    try {
        $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        $windows = $env:WINDIR.TrimEnd('\')
        $pf = $env:ProgramFiles
        $pfx86 = ${env:ProgramFiles(x86)}
        $programData = $env:ProgramData

        if ($full.Equals($windows, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($windows + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($pf -and ($full.Equals($pf, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($pf.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { return $true }
        if ($pfx86 -and ($full.Equals($pfx86, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($pfx86.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { return $true }
        if ($programData -and ($full.Equals($programData, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($programData.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { return $true }
    }
    catch { return $true }

    return $false
}

function Update-UsageBarWidth {
    if (-not $script:selectedPath) { return }
    $d = Get-DriveInfoFor $script:selectedPath
    if (-not $d -or -not $d.IsReady -or $d.TotalSize -le 0) { return }

    [double]$usedRatio = ($d.TotalSize - $d.AvailableFreeSpace) / [double]$d.TotalSize
    if ($usedRatio -lt 0) { $usedRatio = 0 }
    if ($usedRatio -gt 1) { $usedRatio = 1 }

    $UsageFill.Width = $UsageTrack.ActualWidth * $usedRatio
}

function Update-DriveInfo {
    if (-not $script:selectedPath) {
        $UsagePercent.Text = "—"
        $UsedSpaceChart.Text = "—"
        $FreeSpaceChart.Text = "—"
        $TotalSpaceChart.Text = "—"
        $UsageSubtitle.Text = "Disk veya klasör seçtikten sonra kullanım grafiği burada görünür."
        return
    }

    $d = Get-DriveInfoFor $script:selectedPath
    if ($d -and $d.IsReady -and $d.TotalSize -gt 0) {
        [long]$used = $d.TotalSize - $d.AvailableFreeSpace
        [double]$pct = ($used / [double]$d.TotalSize) * 100.0
        $UsedSpaceChart.Text = [DiskLensPremiumV3.Scanner]::FormatBytes($used)
        $FreeSpaceChart.Text = [DiskLensPremiumV3.Scanner]::FormatBytes($d.AvailableFreeSpace)
        $TotalSpaceChart.Text = [DiskLensPremiumV3.Scanner]::FormatBytes($d.TotalSize)
        $UsagePercent.Text = ("{0:N1}%" -f $pct)
        $UsageSubtitle.Text = "Kullanılan ve boş alanın görsel özeti."
        Update-UsageBarWidth
    }
}

function Set-Location([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    $script:selectedPath = $path
    $SidePath.Text = $path
    $ScanButton.IsEnabled = $true
    $RefreshButton.IsEnabled = $true
    Update-DriveInfo
    Set-Status "Konum hazır. Klasör alan haritası için taramaya başlayabilirsin." "#5B4CFF"
}

function Cleanup-Scan {
    try { if ($script:scanPS) { $script:scanPS.Dispose() } } catch {}
    try {
        if ($script:scanRunspace) {
            $script:scanRunspace.Close()
            $script:scanRunspace.Dispose()
        }
    } catch {}
    try { if ($script:pauseGate) { $script:pauseGate.Dispose() } } catch {}

    $script:scanPS = $null
    $script:scanRunspace = $null
    $script:scanAsync = $null
    $script:scanCts = $null
    $script:pauseGate = $null
    $script:progressQueue = $null
}


function script:Matches-Filter([string]$name) {
    try {
        $query = ""
        if ($null -ne $SearchBox -and $null -ne $SearchBox.Text) {
            $query = ([string]$SearchBox.Text).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($query)) {
            return $true
        }

        if ([string]::IsNullOrEmpty($name)) {
            return $false
        }

        return ($name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch {
        # Filtering should never be allowed to break the folder map.
        try { Write-ErrorLog "Arama filtresi hatası" $_.Exception } catch { }
        return $true
    }
}

function Sort-Folders($items) {
    return @($items | Sort-Object TotalBytes -Descending)
}

function Sort-Files($items) {
    return @($items | Sort-Object Bytes -Descending)
}

function Get-IconForFile($file) {
    switch ($file.Category) {
        "Video" { return "🎬" }
        "Arşiv" { return "🗜" }
        "Görsel" { return "🖼" }
        "Ses" { return "🎵" }
        "Belge" { return "📄" }
        default { return "🧩" }
    }
}

function New-NodeMeta([string]$path, [bool]$isFolder, [bool]$isSystemLike, [string]$name, [long]$bytes, [string]$sizeText, [string]$metaText) {
    return [PSCustomObject]@{
        Path = $path
        IsFolder = $isFolder
        IsSystemLike = $isSystemLike
        Name = $name
        Bytes = $bytes
        SizeText = $sizeText
        MetaText = $metaText
        CardBorder = $null
        IconBorder = $null
        NameText = $null
    }
}



function Clear-LiveRecentItems {
    try { $LiveRecentStack.Children.Clear() } catch { }
}

function Add-LiveRecentItem([string]$path, [long]$bytes = 0) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    try {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = [System.Windows.Thickness]::new(0,1,0,1)

        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($c1)
        [void]$row.ColumnDefinitions.Add($c2)

        $name = New-Object System.Windows.Controls.TextBlock
        try { $name.Text = [System.IO.Path]::GetFileName($path) } catch { $name.Text = $path }
        if ([string]::IsNullOrWhiteSpace($name.Text)) { $name.Text = $path }
        $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $name.Foreground = $window.Resources["TextPrimary"]
        $name.FontSize = 10
        $name.ToolTip = $path
        [System.Windows.Controls.Grid]::SetColumn($name,0)
        [void]$row.Children.Add($name)

        $size = New-Object System.Windows.Controls.TextBlock
        $size.Text = if ($bytes -gt 0) { [DiskLensPremiumV3.Scanner]::FormatBytes($bytes) } else { "" }
        $size.Foreground = $window.Resources["TextSecondary"]
        $size.FontSize = 9
        $size.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        $size.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        [System.Windows.Controls.Grid]::SetColumn($size,1)
        [void]$row.Children.Add($size)

        $LiveRecentStack.Children.Insert(0,$row)
        while ($LiveRecentStack.Children.Count -gt 5) {
            $LiveRecentStack.Children.RemoveAt($LiveRecentStack.Children.Count - 1)
        }
    } catch {
        try { Write-ErrorLog "Canlı tarama öğesi gösterilemedi" $_.Exception } catch { }
    }
}

function Start-LiveScanUi([string]$message = "Tarama hazırlanıyor…") {
    try {
        Clear-LiveRecentItems
        $LiveScanCurrentText.Text = $message
        $LiveScanCurrentText.ToolTip = $message
        $LiveScanStats.Text = "0 dosya • 0 klasör"
        $LiveScanPanel.Visibility = [System.Windows.Visibility]::Visible
        $scanAnimationTimer.Start()
    } catch { }
}

function Stop-LiveScanUi {
    try {
        $scanAnimationTimer.Stop()
        $LiveScanSpinner.Text = "✓"
        $LiveScanPanel.Visibility = [System.Windows.Visibility]::Collapsed
    } catch { }
}

function Set-ScanUiLock([bool]$locked, [bool]$selectedOnly = $false) {
    try {
        # Tarama arka planda ayrı runspace'te çalışır.
        # Görüntüleme ağacı eski/stabil sonuçları göstermeye devam eder.
        $FolderTree.IsHitTestVisible = $true
        $SearchBox.IsEnabled = $true
        $ThemeButton.IsEnabled = (-not $script:isApplyingScanResult)

        # Yeni konum/tarama başlatma veri karışmasını önlemek için kapalı.
        $DriveButton.IsEnabled = -not $locked
        $FolderButton.IsEnabled = -not $locked
        $ScanButton.IsEnabled = (-not $locked -and [bool]$script:selectedPath)
        $RefreshButton.IsEnabled = (-not $locked -and [bool]$script:selectedPath)

        if ($locked) {
            # Görüntüleme ve seçme serbest; dosya sistemini değiştiren işlemler kapalı.
            $RenameButton.IsEnabled = $false
            $MoveButton.IsEnabled = $false
            $SelectedRefreshButton.IsEnabled = $false
            $DeleteButton.IsEnabled = $false

            # Explorer'da konumu açmak güvenli; seçili bir öğe varsa kullanılabilir.
            $OpenButton.IsEnabled = ($script:selectedNode -and (Test-Path -LiteralPath $script:selectedNode.Path))

            if ($selectedOnly) {
                $PauseButton.IsEnabled = $false
                $CancelButton.IsEnabled = $true
                $CancelButton.ToolTip = "Seçili öğe taramasını iptal et"
            } else {
                $PauseButton.IsEnabled = $true
                $CancelButton.IsEnabled = $true
                $CancelButton.ToolTip = "Taramayı iptal et"
            }
        } else {
            $PauseButton.IsEnabled = $false
            $CancelButton.IsEnabled = $false
            $CancelButton.ToolTip = $null
            Update-SelectedState
        }
    } catch {
        try { Write-ErrorLog "Tarama UI kilidi uygulanamadı" $_.Exception } catch { }
    }
}

function Update-SelectedState {
    if (-not $script:selectedNode) {
        $SelectedItemText.Text = "Henüz seçim yok"
        $SelectedItemMeta.Text = "—"
        $OpenButton.IsEnabled = $false
        $RenameButton.IsEnabled = $false
        $MoveButton.IsEnabled = $false
        $SelectedRefreshButton.IsEnabled = $false
        $DeleteButton.IsEnabled = $false
        return
    }

    $item = $script:selectedNode
    $SelectedItemText.Text = $item.Name
    $SelectedItemMeta.Text = $item.MetaText

    $exists = Test-Path -LiteralPath $item.Path
    $isDriveRootFolder = ($item.IsFolder -and (Is-DriveRoot $item.Path))

    # Rename/move still stay conservative for protected Windows/program paths.
    $allowChange = ($exists -and -not (Is-ProtectedPath $item.Path) -and -not $isDriveRootFolder)

    # Delete is allowed for warning/system items after explicit confirmation.
    # Only actual drive roots remain blocked.
    $allowDelete = ($exists -and -not $isDriveRootFolder)

    $OpenButton.IsEnabled = $exists

    if ($script:isScanning -or $script:isSelectedScanning -or $script:isApplyingScanResult) {
        $RenameButton.IsEnabled = $false
        $MoveButton.IsEnabled = $false
        $SelectedRefreshButton.IsEnabled = $false
        $DeleteButton.IsEnabled = $false
    }
    else {
        $RenameButton.IsEnabled = $allowChange
        $MoveButton.IsEnabled = $allowChange
        $SelectedRefreshButton.IsEnabled = $exists
        $DeleteButton.IsEnabled = $allowDelete
    }
}

function Set-NodeVisual($meta, [bool]$selected) {
    if (-not $meta -or -not $meta.CardBorder) { return }
    if ($selected) {
        $meta.CardBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#F1EEFF" "#27234A"))
        $meta.CardBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#8B7FFF" "#9A8FFF"))
        $meta.CardBorder.BorderThickness = [System.Windows.Thickness]::new(1.5)
        if ($meta.IconBorder) { $meta.IconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6D5DFB") }
        if ($meta.NameText) { $meta.NameText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#3828B8" "#FFFFFF")) }
    } else {
        $meta.CardBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#FFFFFF" "#131E2D"))
        $meta.CardBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#E4E9F0" "#26364B"))
        $meta.CardBorder.BorderThickness = [System.Windows.Thickness]::new(1.5)
        if ($meta.IconBorder) { $meta.IconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#EEEAFE" "#31405A")) }
        if ($meta.NameText) { $meta.NameText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#1E293B" "#F8FAFC")) }
    }
}

function Select-TreeNode($meta) {
    if ($script:selectedNode -and $script:selectedNode.Path -ne $meta.Path) {
        Set-NodeVisual $script:selectedNode $false
    }
    $script:selectedNode = $meta
    Set-NodeVisual $script:selectedNode $true
    Update-SelectedState
}

function New-FileHeader($file, [long]$parentTotal, [System.Windows.Controls.TreeViewItem]$owner) {
    $meta = New-NodeMeta $file.FullPath $false $file.IsSystemLike $file.Name $file.Bytes $file.SizeText ("Dosya • " + $file.SizeText + " • Değişiklik: " + $file.ModifiedText)
    $owner.Tag = $meta

    $grid = New-Object System.Windows.Controls.Grid
    $grid.MinHeight = 54
    $grid.Margin = [System.Windows.Thickness]::new(0,3,0,3)
    $grid.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $grid.Cursor = [System.Windows.Input.Cursors]::Hand
    $grid.Tag = $meta
    Add-Member -InputObject $grid -MemberType NoteProperty -Name OwnerNode -Value $owner -Force

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = [System.Windows.CornerRadius]::new(13)
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#FFFFFF" "#131E2D"))
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#E4E9F0" "#26364B"))
    $card.BorderThickness = [System.Windows.Thickness]::new(1.5)
    $card.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    [void]$grid.Children.Add($card)

    $inner = New-Object System.Windows.Controls.Grid
    $inner.Margin = [System.Windows.Thickness]::new(12,7,12,7)
    foreach ($w in @("*", "120", "128")) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        if ($w -eq "*") { $c.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star) }
        else { $c.Width = [System.Windows.GridLength]::new([double]$w) }
        [void]$inner.ColumnDefinitions.Add($c)
    }
    [void]$grid.Children.Add($inner)

    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $left.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $iconWrap = New-Object System.Windows.Controls.Border
    $iconWrap.Width = 31; $iconWrap.Height = 31
    $iconWrap.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $iconWrap.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#F1F5F9" "#31405A"))
    $iconWrap.Margin = [System.Windows.Thickness]::new(0,0,9,0)
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Text = [char]0xE8A5
    $glyph.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe MDL2 Assets")
    $glyph.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#475569" "#E2E8F0"))
    $glyph.FontSize = 15
    $glyph.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $iconWrap.Child = $glyph

    $txt = New-Object System.Windows.Controls.StackPanel
    $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $file.Name
    $name.FontWeight = [System.Windows.FontWeights]::SemiBold
    $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $name.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#1E293B" "#F8FAFC"))
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = "$($file.Category) • Değişiklik: $($file.ModifiedText)"
    $sub.FontSize = 10
    $sub.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#64748B" "#9FB1C7"))
    $sub.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    [void]$txt.Children.Add($name); [void]$txt.Children.Add($sub)
    [void]$left.Children.Add($iconWrap); [void]$left.Children.Add($txt)

    if ($file.IsSystemLike) {
        $warn = New-Object System.Windows.Controls.TextBlock
        $warn.Text = "  ⚠"; $warn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F59E0B")
        $warn.ToolTip = "Sistem/gizli dosya. Silinmesi Windows veya uygulamalarda problem çıkarabilir."
        [void]$left.Children.Add($warn)
    }
    [System.Windows.Controls.Grid]::SetColumn($left,0); [void]$inner.Children.Add($left)

    $size = New-Object System.Windows.Controls.TextBlock
    $size.Text = $file.SizeText; $size.FontWeight = [System.Windows.FontWeights]::SemiBold
    $size.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#334155" "#D5DEEA"))
    $size.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right; $size.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($size,1); [void]$inner.Children.Add($size)

    $track = New-Object System.Windows.Controls.Border
    $track.Height=8; $track.Width=112; $track.CornerRadius=[System.Windows.CornerRadius]::new(4); $track.ClipToBounds=$true
    $track.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#E9EEF5" "#26364B"))
    $track.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right; $track.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
    $fill=New-Object System.Windows.Controls.Border
    $ratio=0.0; if($parentTotal -gt 0){$ratio=[Math]::Min(1.0,([double]$file.Bytes/[double]$parentTotal))}
    $fill.Width=112*$ratio; $fill.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Left
    $fill.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString("#6D5DFB"); $fill.CornerRadius=[System.Windows.CornerRadius]::new(4)
    $track.Child=$fill; [System.Windows.Controls.Grid]::SetColumn($track,2); [void]$inner.Children.Add($track)

    $meta.CardBorder=$card; $meta.IconBorder=$iconWrap; $meta.NameText=$name
    $grid.Add_MouseLeftButtonUp({ param($sender,$e) if($script:isApplyingScanResult){$e.Handled=$true; return}; $node=$sender.OwnerNode; $node.IsSelected=$true; Select-TreeNode $sender.Tag; $e.Handled=$true })
    return $grid
}

function New-FolderHeader($folder, [long]$parentTotal, [System.Windows.Controls.TreeViewItem]$owner) {
    $meta = New-NodeMeta $folder.FullPath $true $folder.IsSystemLike $folder.Name $folder.TotalBytes $folder.SizeText ("Klasör • " + $folder.SizeText + " • Değişiklik: " + $folder.ModifiedText)
    $owner.Tag = $meta

    $grid = New-Object System.Windows.Controls.Grid
    $grid.MinHeight = 62
    $grid.Margin = [System.Windows.Thickness]::new(0,3,0,3)
    $grid.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $grid.Cursor = [System.Windows.Input.Cursors]::Hand
    $grid.Tag = $meta
    Add-Member -InputObject $grid -MemberType NoteProperty -Name OwnerNode -Value $owner -Force

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = [System.Windows.CornerRadius]::new(14)
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#FFFFFF" "#131E2D"))
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#E4E9F0" "#26364B"))
    $card.BorderThickness = [System.Windows.Thickness]::new(1.5)
    $card.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    [void]$grid.Children.Add($card)

    $inner = New-Object System.Windows.Controls.Grid
    $inner.Margin = [System.Windows.Thickness]::new(12,7,12,7)
    foreach ($w in @("*", "120", "128")) {
        $c=New-Object System.Windows.Controls.ColumnDefinition
        if($w -eq "*"){$c.Width=[System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)}else{$c.Width=[System.Windows.GridLength]::new([double]$w)}
        [void]$inner.ColumnDefinitions.Add($c)
    }
    [void]$grid.Children.Add($inner)

    $left=New-Object System.Windows.Controls.StackPanel; $left.Orientation=[System.Windows.Controls.Orientation]::Horizontal; $left.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
    $iconWrap=New-Object System.Windows.Controls.Border; $iconWrap.Width=34; $iconWrap.Height=34; $iconWrap.CornerRadius=[System.Windows.CornerRadius]::new(10)
    $iconWrap.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#EEEAFE" "#31405A")); $iconWrap.Margin=[System.Windows.Thickness]::new(0,0,9,0)
    $glyph=New-Object System.Windows.Controls.TextBlock; $glyph.Text=[char]0xE8B7; $glyph.FontFamily=[System.Windows.Media.FontFamily]::new("Segoe MDL2 Assets")
    $glyph.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#5B4CFF" "#E8E4FF")); $glyph.FontSize=17
    $glyph.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Center; $glyph.VerticalAlignment=[System.Windows.VerticalAlignment]::Center; $iconWrap.Child=$glyph

    $txt=New-Object System.Windows.Controls.StackPanel; $txt.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
    $name=New-Object System.Windows.Controls.TextBlock; $name.Text=$folder.Name; $name.FontWeight=[System.Windows.FontWeights]::SemiBold
    $name.TextTrimming=[System.Windows.TextTrimming]::CharacterEllipsis; $name.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#1E293B" "#F8FAFC"))
    $sub=New-Object System.Windows.Controls.TextBlock; $sub.Text="Doğrudan: $($folder.DirectSizeText) • $($folder.FilesText) dosya • Değişiklik: $($folder.ModifiedText)"
    $sub.FontSize=10; $sub.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#64748B" "#9FB1C7")); $sub.Margin=[System.Windows.Thickness]::new(0,2,0,0)
    [void]$txt.Children.Add($name); [void]$txt.Children.Add($sub); [void]$left.Children.Add($iconWrap); [void]$left.Children.Add($txt)

    if($folder.IsSystemLike){$warn=New-Object System.Windows.Controls.TextBlock; $warn.Text="  ⚠"; $warn.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString("#F59E0B"); $warn.ToolTip="Sistem/gizli klasör. Silinmesi Windows veya uygulamalarda problem çıkarabilir."; [void]$left.Children.Add($warn)}
    [System.Windows.Controls.Grid]::SetColumn($left,0); [void]$inner.Children.Add($left)

    $size=New-Object System.Windows.Controls.TextBlock; $size.Text=$folder.SizeText; $size.FontWeight=[System.Windows.FontWeights]::SemiBold
    $size.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#334155" "#D5DEEA")); $size.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right; $size.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($size,1); [void]$inner.Children.Add($size)

    $track=New-Object System.Windows.Controls.Border; $track.Height=9; $track.Width=112; $track.CornerRadius=[System.Windows.CornerRadius]::new(5); $track.ClipToBounds=$true
    $track.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString((Theme-Color "#E9EEF5" "#26364B")); $track.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right; $track.VerticalAlignment=[System.Windows.VerticalAlignment]::Center
    $fill=New-Object System.Windows.Controls.Border; $ratio=0.0; if($parentTotal -gt 0){$ratio=[Math]::Min(1.0,([double]$folder.TotalBytes/[double]$parentTotal))}
    $fill.Width=112*$ratio; $fill.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Left; $fill.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString("#6D5DFB"); $fill.CornerRadius=[System.Windows.CornerRadius]::new(5)
    $track.Child=$fill; [System.Windows.Controls.Grid]::SetColumn($track,2); [void]$inner.Children.Add($track)

    $meta.CardBorder=$card; $meta.IconBorder=$iconWrap; $meta.NameText=$name
    $grid.Add_MouseLeftButtonUp({ param($sender,$e) if($script:isApplyingScanResult){$e.Handled=$true; return}; $node=$sender.OwnerNode; $node.IsSelected=$true; Select-TreeNode $sender.Tag; if($node.HasItems){$node.IsExpanded=-not $node.IsExpanded}; $e.Handled=$true })
    return $grid
}

function Add-BranchChildren([System.Windows.Controls.TreeViewItem]$node) {
    if ($node.PSObject.Properties["ChildrenLoaded"] -and $node.ChildrenLoaded) { return }

    $path = [string]$node.Tag.Path
    $node.Items.Clear()

    $parentTotal = 0
    if ($script:folderByPath.ContainsKey($path)) { $parentTotal = [long]$script:folderByPath[$path].TotalBytes }

    $folders = @()
    if ($script:childrenByParent.ContainsKey($path)) {
        $folders = Sort-Folders @($script:childrenByParent[$path] | Where-Object { script:Matches-Filter $_.Name })
    }

    foreach ($folder in $folders) {
        $child = New-Object System.Windows.Controls.TreeViewItem
        Add-Member -InputObject $child -MemberType NoteProperty -Name ChildrenLoaded -Value $false -Force
        $child.Header = New-FolderHeader $folder $parentTotal $child

        $hasSubFolders = $script:childrenByParent.ContainsKey($folder.FullPath) -and @($script:childrenByParent[$folder.FullPath]).Count -gt 0
        $hasFiles = $script:filesByParent.ContainsKey($folder.FullPath) -and @($script:filesByParent[$folder.FullPath]).Count -gt 0
        if ($hasSubFolders -or $hasFiles) { [void]$child.Items.Add("...") }

        $child.Add_Expanded({
            param($sender,$e)
            try {
                Add-BranchChildren $sender
            }
            catch {
                $raw = ""
                try { $raw = ($_ | Out-String) } catch { }
                Show-AppError "Alt klasör açma hatası" $_.Exception $raw
            }
            $e.Handled = $true
        })

        $child.Add_Selected({
            param($sender,$e)
            Select-TreeNode $sender.Tag
        })

        [void]$node.Items.Add($child)
    }

    $files = @()
    if ($script:filesByParent.ContainsKey($path)) {
        $files = Sort-Files @($script:filesByParent[$path] | Where-Object { script:Matches-Filter $_.Name })
    }

    foreach ($file in $files) {
        $leaf = New-Object System.Windows.Controls.TreeViewItem
        Add-Member -InputObject $leaf -MemberType NoteProperty -Name ChildrenLoaded -Value $true -Force
        $leaf.Header = New-FileHeader $file $parentTotal $leaf
        $leaf.Add_Selected({
            param($sender,$e)
            Select-TreeNode $sender.Tag
        })
        [void]$node.Items.Add($leaf)
    }

    $node.ChildrenLoaded = $true
}

function Build-Indexes {
    $script:folderByPath = @{}
    $script:childrenByParent = @{}
    $script:filesByParent = @{}

    foreach ($folder in $script:allFolders) {
        $script:folderByPath[$folder.FullPath] = $folder
        if (-not $script:childrenByParent.ContainsKey($folder.ParentPath)) {
            $script:childrenByParent[$folder.ParentPath] = New-Object System.Collections.ArrayList
        }
        [void]$script:childrenByParent[$folder.ParentPath].Add($folder)
    }

    foreach ($file in $script:allFiles) {
        if (-not $script:filesByParent.ContainsKey($file.ParentPath)) {
            $script:filesByParent[$file.ParentPath] = New-Object System.Collections.ArrayList
        }
        [void]$script:filesByParent[$file.ParentPath].Add($file)
    }
}


function Recalculate-FolderTotals {
    try {
        $totals = @{}

        foreach ($folder in $script:allFolders) {
            $totals[$folder.FullPath] = [long]$folder.DirectBytes
        }

        $ordered = @($script:allFolders | Sort-Object @{Expression={ $_.FullPath.Length }; Descending=$true})

        foreach ($folder in $ordered) {
            $value = [long]$totals[$folder.FullPath]
            $parent = [string]$folder.ParentPath

            if ($parent -and $totals.ContainsKey($parent)) {
                $totals[$parent] = [long]$totals[$parent] + $value
            }
        }

        foreach ($folder in $script:allFolders) {
            if ($totals.ContainsKey($folder.FullPath)) {
                $folder.TotalBytes = [long]$totals[$folder.FullPath]
                $folder.SizeText = [DiskLensPremiumV3.Scanner]::FormatBytes($folder.TotalBytes)
            }
        }
    }
    catch {
        $raw = ""
        try { $raw = ($_ | Out-String) } catch { }
        Show-AppError "Klasör toplamları güncellenemedi" $_.Exception $raw
    }
}

function Get-ExpandedTreePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    function Walk-Expanded($items) {
        foreach ($node in $items) {
            if ($node -is [System.Windows.Controls.TreeViewItem]) {
                try {
                    if ($node.IsExpanded -and $node.Tag -and $node.Tag.Path) {
                        [void]$paths.Add([string]$node.Tag.Path)
                    }
                } catch { }

                try { Walk-Expanded $node.Items } catch { }
            }
        }
    }

    try { Walk-Expanded $FolderTree.Items } catch { }
    return @($paths)
}

function Find-TreeNodeByPath($items, [string]$path) {
    foreach ($node in $items) {
        if ($node -is [System.Windows.Controls.TreeViewItem]) {
            try {
                if ($node.Tag -and [string]$node.Tag.Path -eq $path) {
                    return $node
                }
            } catch { }

            try {
                $found = Find-TreeNodeByPath $node.Items $path
                if ($found) { return $found }
            } catch { }
        }
    }

    return $null
}

function Restore-TreeState($expandedPaths, [string]$selectedPath) {
    $expandedSet = @{}
    foreach ($p in @($expandedPaths)) {
        if ($p) { $expandedSet[[string]$p] = $true }
    }

    function Restore-Nodes($items) {
        foreach ($node in $items) {
            if ($node -is [System.Windows.Controls.TreeViewItem]) {
                $path = ""
                try { $path = [string]$node.Tag.Path } catch { }

                if ($path -and $expandedSet.ContainsKey($path)) {
                    try {
                        if ($node.PSObject.Properties["ChildrenLoaded"] -and -not $node.ChildrenLoaded) {
                            Add-BranchChildren $node
                        }
                        $node.IsExpanded = $true
                    } catch { }
                }

                try { Restore-Nodes $node.Items } catch { }
            }
        }
    }

    try { Restore-Nodes $FolderTree.Items } catch { }

    if ($selectedPath) {
        try {
            $node = Find-TreeNodeByPath $FolderTree.Items $selectedPath
            if ($node) {
                $node.IsSelected = $true
                Select-TreeNode $node.Tag
                return
            }
        } catch { }

        # Even if a deeply nested node is not materialized, keep sidebar state.
        try {
            if ($script:folderByPath.ContainsKey($selectedPath)) {
                $folder = $script:folderByPath[$selectedPath]
                $meta = New-NodeMeta $folder.FullPath $true $folder.IsSystemLike $folder.Name $folder.TotalBytes $folder.SizeText ("Klasör • " + $folder.SizeText + " • Değişiklik: " + $folder.ModifiedText)
                Select-TreeNode $meta
            }
        } catch { }
    }
}

function Update-SummaryFromCurrentData([long]$elapsedMs = 0) {
    try {
        [long]$fileCount = 0
        foreach ($folder in $script:allFolders) {
            $fileCount += [long]$folder.DirectFiles
        }

        $elapsedText = if ($elapsedMs -gt 0) { Format-Time $elapsedMs } else { "—" }
        $SummaryStat.Text = "$($fileCount.ToString('N0')) / $($script:allFolders.Count.ToString('N0')) / $elapsedText"
    } catch { }
}

function Cleanup-SelectedScan {
    try { if ($script:selectedScanPS) { $script:selectedScanPS.Dispose() } } catch {}
    try {
        if ($script:selectedScanRunspace) {
            $script:selectedScanRunspace.Close()
            $script:selectedScanRunspace.Dispose()
        }
    } catch {}
    try { if ($script:selectedScanPause) { $script:selectedScanPause.Dispose() } } catch {}

    $script:selectedScanPS = $null
    $script:selectedScanRunspace = $null
    $script:selectedScanAsync = $null
    $script:selectedScanCts = $null
    $script:selectedScanPause = $null
    $script:selectedScanQueue = $null
    $script:selectedScanTarget = $null
}

function Refresh-SelectedFile([string]$path) {
    $old = $script:allFiles | Where-Object { $_.FullPath -eq $path } | Select-Object -First 1
    if (-not $old) {
        throw "Seçili dosya mevcut tarama verisinde bulunamadı."
    }

    $parent = $script:folderByPath[$old.ParentPath]
    [long]$oldBytes = [long]$old.Bytes

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:allFiles = @($script:allFiles | Where-Object { $_.FullPath -ne $path })

        if ($parent) {
            [long]$newDirectBytes = ([long]$parent.DirectBytes - [long]$oldBytes)
            if ($newDirectBytes -lt 0) { $newDirectBytes = 0L }
            $parent.DirectBytes = $newDirectBytes

            [long]$newDirectFiles = ([long]$parent.DirectFiles - 1L)
            if ($newDirectFiles -lt 0) { $newDirectFiles = 0L }
            $parent.DirectFiles = $newDirectFiles
            $parent.DirectSizeText = [DiskLensPremiumV3.Scanner]::FormatBytes($parent.DirectBytes)
            $parent.FilesText = $parent.DirectFiles.ToString("N0")
        }

        Recalculate-FolderTotals
        Build-Indexes
        return
    }

    $fi = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    [long]$newBytes = [long]$fi.Length
    [long]$delta = $newBytes - $oldBytes

    if ($parent) {
        [long]$newDirectBytes = ([long]$parent.DirectBytes + [long]$delta)
        if ($newDirectBytes -lt 0) { $newDirectBytes = 0L }
        $parent.DirectBytes = $newDirectBytes
        $parent.DirectSizeText = [DiskLensPremiumV3.Scanner]::FormatBytes($parent.DirectBytes)
    }

    [long]$minBytes = 10485760
    try { $minBytes = [long]$MinSizeBox.SelectedItem.Tag } catch {}

    if ($newBytes -lt $minBytes) {
        $script:allFiles = @($script:allFiles | Where-Object { $_.FullPath -ne $path })
    }
    else {
        $old.Bytes = $newBytes
        $old.SizeText = [DiskLensPremiumV3.Scanner]::FormatBytes($newBytes)
        $old.Modified = $fi.LastWriteTime
        $old.ModifiedText = $fi.LastWriteTime.ToString("dd.MM.yyyy HH:mm")

        $attrs = $fi.Attributes
        $old.IsSystemLike = (($attrs -band [System.IO.FileAttributes]::Hidden) -ne 0 -or ($attrs -band [System.IO.FileAttributes]::System) -ne 0)
    }

    Recalculate-FolderTotals
    Build-Indexes
}

function Merge-SelectedFolderScan($result, [string]$target) {
    $targetTrim = $target.TrimEnd('\')
    $prefix = $targetTrim + '\'

    $script:allFolders = @(
        $script:allFolders | Where-Object {
            $p = [string]$_.FullPath
            -not (
                $p.Equals($targetTrim, [StringComparison]::OrdinalIgnoreCase) -or
                $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            )
        }
    )

    $script:allFiles = @(
        $script:allFiles | Where-Object {
            $p = [string]$_.FullPath
            -not (
                $p.Equals($targetTrim, [StringComparison]::OrdinalIgnoreCase) -or
                $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            )
        }
    )

    $script:allFolders += @($result.Folders)
    $script:allFiles += @($result.Files)

    Recalculate-FolderTotals
    Build-Indexes
}

function Start-SelectedRescan {
    if ($script:isScanning -or $script:isSelectedScanning) { return }
    if (-not $script:selectedNode) { return }

    $item = $script:selectedNode
    $target = [string]$item.Path

    if (-not (Test-Path -LiteralPath $target)) {
        Show-AppError "Seçili öğe tekrar taranamadı" $null "Öğe artık mevcut değil: $target"
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Sadece seçili öğeyi tekrar taratmak istiyor musunuz?`n`n$target",
        "Seçili öğeyi tekrar tara",
        "YesNo",
        "Question"
    )
    if ($confirm -ne "Yes") { return }

    $expanded = Get-ExpandedTreePaths
    $selectedPath = $target

    if (-not $item.IsFolder) {
        try {
            Refresh-SelectedFile $target
            Rebuild-Tree
            Restore-TreeState $expanded $selectedPath
            Update-DriveInfo
            Update-SummaryFromCurrentData
            Set-Status "Seçili dosya tekrar tarandı." "#16A34A"
            Show-Notification "Seçili dosya güncellendi." "success"
        }
        catch {
            $raw = ""
            try { $raw = ($_ | Out-String) } catch { }
            Show-AppError "Seçili dosya tekrar taranamadı" $_.Exception $raw
        }
        return
    }

    [long]$minBytes = 10485760
    try { $minBytes = [long]$MinSizeBox.SelectedItem.Tag } catch {}

    $workers = 12
    try { $workers = [int]$WorkerBox.SelectedItem.Tag } catch {}

    $limit = 250000
    try { $limit = [int]$LimitBox.SelectedItem.Tag } catch {}

    $script:selectedScanTarget = $target
    $script:selectedScanExpandedPaths = @($expanded)
    $script:selectedScanCts = New-Object System.Threading.CancellationTokenSource
    $script:selectedScanPause = New-Object -TypeName System.Threading.ManualResetEventSlim -ArgumentList $true
    $script:selectedScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    $script:selectedScanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:selectedScanRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:selectedScanRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:selectedScanRunspace.Open()

    $script:selectedScanPS = [PowerShell]::Create()
    $script:selectedScanPS.Runspace = $script:selectedScanRunspace
    try { $script:selectedScanPS.Streams.Error.Clear() } catch {}

    $selectedScanCode = @'
param($root, $hidden, $minBytes, $limit, $workers, $queue, $pause, $token)
[DiskLensPremiumV3.Scanner]::Scan($root, $true, $hidden, $minBytes, $limit, $workers, $queue, $pause, $token)
'@

    [void]$script:selectedScanPS.AddScript($selectedScanCode)
    [void]$script:selectedScanPS.AddArgument($target)
    [void]$script:selectedScanPS.AddArgument([bool]$HiddenCheck.IsChecked)
    [void]$script:selectedScanPS.AddArgument($minBytes)
    [void]$script:selectedScanPS.AddArgument($limit)
    [void]$script:selectedScanPS.AddArgument($workers)
    [void]$script:selectedScanPS.AddArgument($script:selectedScanQueue)
    [void]$script:selectedScanPS.AddArgument($script:selectedScanPause)
    [void]$script:selectedScanPS.AddArgument($script:selectedScanCts.Token)

    $script:selectedScanAsync = $script:selectedScanPS.BeginInvoke()
    $script:isSelectedScanning = $true

    Set-ScanUiLock $true $true

    Start-LiveScanUi ("Seçili klasör: " + $target)
    Set-Status "Seçili klasör taranıyor… Diğer sonuçları görüntüleyebilirsiniz." "#5B4CFF"
    Show-Notification "Seçili klasör tekrar taranıyor." "info"

    $selectedScanTimer.Start()
}

function Rebuild-Tree {
    $FolderTree.Items.Clear()
    if (-not $script:rootPath -or -not $script:folderByPath.ContainsKey($script:rootPath)) {
        $script:selectedNode = $null
        Update-SelectedState
        return
    }

    $rootFolder = $script:folderByPath[$script:rootPath]
    $rootNode = New-Object System.Windows.Controls.TreeViewItem
    Add-Member -InputObject $rootNode -MemberType NoteProperty -Name ChildrenLoaded -Value $false -Force
    $rootNode.Header = New-FolderHeader $rootFolder $rootFolder.TotalBytes $rootNode

    $hasRootSub = $script:childrenByParent.ContainsKey($script:rootPath) -and @($script:childrenByParent[$script:rootPath]).Count -gt 0
    $hasRootFiles = $script:filesByParent.ContainsKey($script:rootPath) -and @($script:filesByParent[$script:rootPath]).Count -gt 0
    if ($hasRootSub -or $hasRootFiles) { [void]$rootNode.Items.Add("...") }

    $rootNode.Add_Expanded({
        param($sender,$e)
        try {
            Add-BranchChildren $sender
        }
        catch {
            $raw = ""
            try { $raw = ($_ | Out-String) } catch { }
            Show-AppError "Kök klasör açma hatası" $_.Exception $raw
        }
        $e.Handled = $true
    })
    $rootNode.Add_Selected({
        param($sender,$e)
        Select-TreeNode $sender.Tag
    })

    [void]$FolderTree.Items.Add($rootNode)

    # Expanding the node triggers Add-BranchChildren through the Expanded event.
    # Do not call it twice; this avoids duplicate UI work and event re-entry.
    $rootNode.IsExpanded = $true
    $rootNode.IsSelected = $true
    Select-TreeNode $rootNode.Tag
}

function Rescan {
    if ($script:isScanning -or $script:isSelectedScanning -or -not $script:selectedPath) { return }

    [long]$minBytes = 10485760
    try { $minBytes = [long]$MinSizeBox.SelectedItem.Tag } catch {}

    $workers = 12
    try { $workers = [int]$WorkerBox.SelectedItem.Tag } catch {}

    $limit = 250000
    try { $limit = [int]$LimitBox.SelectedItem.Tag } catch {}

    # Mevcut sonuçları tarama boyunca ekranda tut.
    # Yeni tarama ayrı veri yapısında hazırlanır ve yalnızca tamamlanınca atomik olarak uygulanır.
    $SummaryStat.Text = "0 / 0 / taranıyor"

    $script:scanCts = New-Object System.Threading.CancellationTokenSource
    $script:pauseGate = New-Object -TypeName System.Threading.ManualResetEventSlim -ArgumentList $true
    $script:progressQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:scanRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:scanRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:scanRunspace.Open()

    $script:scanPS = [PowerShell]::Create()
    $script:scanPS.Runspace = $script:scanRunspace
    try { $script:scanPS.Streams.Error.Clear() } catch { }

    $scanCode = @'
param($root, $recursive, $hidden, $minBytes, $limit, $workers, $queue, $pause, $token)
[DiskLensPremiumV3.Scanner]::Scan($root, $recursive, $hidden, $minBytes, $limit, $workers, $queue, $pause, $token)
'@

    [void]$script:scanPS.AddScript($scanCode)
    [void]$script:scanPS.AddArgument($script:selectedPath)
    [void]$script:scanPS.AddArgument([bool]$RecursiveCheck.IsChecked)
    [void]$script:scanPS.AddArgument([bool]$HiddenCheck.IsChecked)
    [void]$script:scanPS.AddArgument($minBytes)
    [void]$script:scanPS.AddArgument($limit)
    [void]$script:scanPS.AddArgument($workers)
    [void]$script:scanPS.AddArgument($script:progressQueue)
    [void]$script:scanPS.AddArgument($script:pauseGate)
    [void]$script:scanPS.AddArgument($script:scanCts.Token)

    $script:scanAsync = $script:scanPS.BeginInvoke()
    $script:isScanning = $true
    $script:isPaused = $false

    $PauseButton.Content = "Duraklat"
    Set-ScanUiLock $true $false

    Start-LiveScanUi ("Başlangıç: " + $script:selectedPath)
    Set-Status "Taranıyor… Mevcut sonuçları görüntülemeye devam edebilirsiniz." "#5B4CFF"
    $pollTimer.Start()
}


$scanAnimationTimer = New-Object System.Windows.Threading.DispatcherTimer
$scanAnimationTimer.Interval = [TimeSpan]::FromMilliseconds(130)
$scanAnimationTimer.Add_Tick({
    try {
        $script:scanSpinnerIndex = ($script:scanSpinnerIndex + 1) % $script:scanSpinnerFrames.Count
        $LiveScanSpinner.Text = $script:scanSpinnerFrames[$script:scanSpinnerIndex]
    } catch { }
})

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$pollTimer.Add_Tick({
    if (-not $script:isScanning) { return }

    if ($script:progressQueue) {
        $msg = $null
        $processed = 0

        # Bir UI tick'inde sınırsız kuyruk boşaltmak yerine en fazla 24 mesaj işle.
        # Bu, hızlı SSD taramasında UI thread'inin donmasını engeller.
        while ($processed -lt 24 -and $script:progressQueue.TryDequeue([ref]$msg)) {
            $processed++

            if ($msg -is [DiskLensPremiumV3.ScanProgress]) {
                $SummaryStat.Text = "$($msg.Files.ToString('N0')) / $($msg.Dirs.ToString('N0')) / taranıyor"
                $LiveScanStats.Text = "$($msg.Files.ToString('N0')) dosya • $($msg.Dirs.ToString('N0')) klasör"
                $SkippedText.Text = if ($msg.Skipped -gt 0) { "$($msg.Skipped) öğe atlandı" } else { "" }

                if (-not $script:isPaused) {
                    $current = [string]$msg.CurrentItem
                    if ([string]::IsNullOrWhiteSpace($current)) { $current = [string]$msg.CurrentFolder }

                    $LiveScanCurrentText.Text = $current
                    $LiveScanCurrentText.ToolTip = $current
                    Add-LiveRecentItem $current ([long]$msg.CurrentItemBytes)

                    $short = $current
                    if ($short.Length -gt 100) { $short = "…" + $short.Substring($short.Length - 99) }
                    Set-Status "Taranıyor: $short" "#5B4CFF"
                }
            }
        }
    }

    if ($script:scanAsync -and $script:scanAsync.IsCompleted) {
        $pollTimer.Stop()

        try {
            $output = $script:scanPS.EndInvoke($script:scanAsync)

            # Background runspace can report non-terminating errors without throwing.
            $streamText = ""
            try {
                if ($script:scanPS.Streams.Error.Count -gt 0) {
                    $streamText = (($script:scanPS.Streams.Error | ForEach-Object { $_.ToString() }) -join "`r`n")
                }
            } catch { }

            if (-not [string]::IsNullOrWhiteSpace($streamText)) {
                Show-AppError "Tarama motoru hatası" $null $streamText
                return
            }

            $result = $null
            if ($output -and $output.Count -gt 0) {
                $last = $output[$output.Count - 1]
                if ($last.PSObject.Properties["BaseObject"]) { $result = $last.BaseObject } else { $result = $last }
                if (-not $result) { $result = $last }
            }

            if (-not $result) {
                Show-AppError "Tarama sonucu alınamadı" $null "Tarama motoru sonuç döndürmedi. Bu hata ayrıntısı panoya kopyalandı."
                return
            }

            $script:isApplyingScanResult = $true
            $FolderTree.IsHitTestVisible = $false
            $SearchBox.IsEnabled = $false
            $ThemeButton.IsEnabled = $false
            $LiveScanCurrentText.Text = "Sonuçlar hazırlanıyor…"

            $script:rootPath = [string]$result.RootPath
            $script:allFiles = @($result.Files)
            $script:allFolders = @($result.Folders)

            try {
                Build-Indexes
            }
            catch {
                Show-AppError "Tarama sonrası indeks oluşturma hatası" $_.Exception ($_ | Out-String)
                return
            }

            try {
                Rebuild-Tree
            }
            catch {
                Show-AppError "Klasör alan haritası oluşturma hatası" $_.Exception ($_ | Out-String)
                return
            }

            try {
                Update-DriveInfo
            }
            catch {
                Show-AppError "Disk grafiği güncelleme hatası" $_.Exception ($_ | Out-String)
            }

            $SummaryStat.Text = "$($result.FileCount.ToString('N0')) / $($result.DirCount.ToString('N0')) / $(Format-Time $result.ElapsedMilliseconds)"
            $SkippedText.Text = if ($result.Skipped -gt 0) { "$($result.Skipped) erişilemeyen/junction öğe atlandı" } else { "" }

            $suffix = ""
            if ($result.Truncated) { $suffix = " Liste limiti doldu; gerekirse yükselt." }

            if ($result.Cancelled) {
                Set-Status ("Tarama iptal edildi. Tamamlanan sonuçlar gösteriliyor." + $suffix) "#D97706"
            } else {
                Set-Status ("Tarama tamamlandı • $($result.WorkerCount) paralel işçi • min. $([DiskLensPremiumV3.Scanner]::FormatBytes($result.MinFileBytes))." + $suffix) "#16A34A"
            }
        }
        catch {
            $raw = ""
            try { $raw = ($_ | Out-String) } catch { }
            Show-AppError "Tarama işleme hatası" $_.Exception $raw
        }
        finally {
            $script:isScanning = $false
            $script:isPaused = $false
            $script:isApplyingScanResult = $false
            $FolderTree.IsHitTestVisible = $true
            $SearchBox.IsEnabled = $true
            $ThemeButton.IsEnabled = $true
            $PauseButton.Content = "Duraklat"
            Cleanup-Scan
            Stop-LiveScanUi
            Set-ScanUiLock $false $false
        }
    }
})


$selectedScanTimer = New-Object System.Windows.Threading.DispatcherTimer
$selectedScanTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$selectedScanTimer.Add_Tick({
    if (-not $script:isSelectedScanning) { return }

    if ($script:selectedScanQueue) {
        $msg = $null
        $processed = 0

        while ($processed -lt 24 -and $script:selectedScanQueue.TryDequeue([ref]$msg)) {
            $processed++

            if ($msg -is [DiskLensPremiumV3.ScanProgress]) {
                $current = [string]$msg.CurrentItem
                if ([string]::IsNullOrWhiteSpace($current)) { $current = [string]$msg.CurrentFolder }

                $LiveScanStats.Text = "$($msg.Files.ToString('N0')) dosya • $($msg.Dirs.ToString('N0')) klasör"
                $LiveScanCurrentText.Text = $current
                $LiveScanCurrentText.ToolTip = $current
                Add-LiveRecentItem $current ([long]$msg.CurrentItemBytes)

                $pathText = $current
                if ($pathText.Length -gt 100) { $pathText = "…" + $pathText.Substring($pathText.Length - 99) }
                Set-Status "Seçili klasör taranıyor: $pathText" "#5B4CFF"
            }
        }
    }

    if ($script:selectedScanAsync -and $script:selectedScanAsync.IsCompleted) {
        $selectedScanTimer.Stop()

        $target = $script:selectedScanTarget
        $expanded = @($script:selectedScanExpandedPaths)

        try {
            $output = $script:selectedScanPS.EndInvoke($script:selectedScanAsync)

            $streamText = ""
            try {
                if ($script:selectedScanPS.Streams.Error.Count -gt 0) {
                    $streamText = (($script:selectedScanPS.Streams.Error | ForEach-Object { $_.ToString() }) -join "`r`n")
                }
            } catch {}

            if (-not [string]::IsNullOrWhiteSpace($streamText)) {
                Show-AppError "Seçili klasör tarama hatası" $null $streamText
                return
            }

            $result = $null
            if ($output -and $output.Count -gt 0) {
                $last = $output[$output.Count - 1]
                if ($last.PSObject.Properties["BaseObject"]) { $result = $last.BaseObject } else { $result = $last }
                if (-not $result) { $result = $last }
            }

            if (-not $result) {
                Show-AppError "Seçili klasör tekrar taranamadı" $null "Tarama motoru sonuç döndürmedi."
                return
            }

            $script:isApplyingScanResult = $true
            $FolderTree.IsHitTestVisible = $false
            $LiveScanCurrentText.Text = "Seçili klasör sonuçları uygulanıyor…"

            Merge-SelectedFolderScan $result $target
            Rebuild-Tree
            Restore-TreeState $expanded $target
            Update-DriveInfo
            Update-SummaryFromCurrentData $result.ElapsedMilliseconds

            Set-Status "Seçili klasör tekrar tarandı." "#16A34A"
            Show-Notification "Seçili klasör güncellendi." "success"
        }
        catch {
            $raw = ""
            try { $raw = ($_ | Out-String) } catch {}
            Show-AppError "Seçili klasör tekrar tarama hatası" $_.Exception $raw
        }
        finally {
            $script:isSelectedScanning = $false
            $script:isApplyingScanResult = $false
            $FolderTree.IsHitTestVisible = $true
            $SearchBox.IsEnabled = $true
            $ThemeButton.IsEnabled = $true
            Cleanup-SelectedScan
            Stop-LiveScanUi
            Set-ScanUiLock $false $false
        }
    }
})

$filterTimer = New-Object System.Windows.Threading.DispatcherTimer
$filterTimer.Interval = [TimeSpan]::FromMilliseconds(280)
$filterTimer.Add_Tick({
    $filterTimer.Stop()
    if ($script:isApplyingScanResult) { return }

    try {
        Rebuild-Tree
    } catch {
        $raw = ""
        try { $raw = ($_ | Out-String) } catch {}
        Show-AppError "Arama sonucu görünümü yenilenemedi" $_.Exception $raw
    }
})

$TitleBarGrid.Add_MouseLeftButtonDown({
    try {
        if ($_.OriginalSource -is [System.Windows.Controls.Primitives.ButtonBase]) { return }

        if ($_.ClickCount -eq 2) {
            if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' }
        } else {
            $window.DragMove()
        }
    } catch {
        try { Write-ErrorLog "Pencere sürükleme hatası" $_.Exception } catch { }
    }
})

$MinButton.Add_Click({ $window.WindowState = 'Minimized' })
$MaxButton.Add_Click({
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' }
})
$CloseButton.Add_Click({ $window.Close() })

$ThemeButton.Add_Click({
    if ($script:isApplyingScanResult) { return }
    $keepPath = $null
    if ($script:selectedNode) { $keepPath = $script:selectedNode.Path }

    $script:isDark = -not $script:isDark
    Apply-Theme $script:isDark

    # Tree rebuild keeps geometry stable; selected item is restored by path.
    Rebuild-Tree

    if ($keepPath) {
        try {
            function Find-NodeByPath($items, [string]$path) {
                foreach ($node in $items) {
                    if ($node -is [System.Windows.Controls.TreeViewItem]) {
                        try {
                            if ($node.Tag -and [string]$node.Tag.Path -eq $path) { return $node }
                        } catch { }

                        $found = Find-NodeByPath $node.Items $path
                        if ($found) { return $found }
                    }
                }
                return $null
            }

            $restore = Find-NodeByPath $FolderTree.Items $keepPath
            if ($restore) {
                $restore.IsSelected = $true
                Select-TreeNode $restore.Tag
            }
        } catch {
            try { Write-ErrorLog "Tema sonrası seçim geri yüklenemedi" $_.Exception } catch { }
        }
    }

    Show-Notification "Tema değiştirildi." "info"
})

$UsageTrack.Add_SizeChanged({ Update-UsageBarWidth })

$DriveButton.Add_Click({
    $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    if ($drives.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Kullanılabilir sabit disk bulunamadı.", "DiskLens Premium V3.2.9") | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Disk seç"
    $form.Width = 470
    $form.Height = 180
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Left = 20; $combo.Top = 22; $combo.Width = 410
    $combo.DropDownStyle = "DropDownList"
    foreach ($d in $drives) {
        $text = "{0} — Boş {1} / {2}" -f $d.Name,
            [DiskLensPremiumV3.Scanner]::FormatBytes($d.AvailableFreeSpace),
            [DiskLensPremiumV3.Scanner]::FormatBytes($d.TotalSize)
        [void]$combo.Items.Add($text)
    }
    $combo.SelectedIndex = 0

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Seç"; $ok.Left = 330; $ok.Top = 72; $ok.Width = 100
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($combo); $form.Controls.Add($ok); $form.AcceptButton = $ok

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Location $drives[$combo.SelectedIndex].Name
    }
    $form.Dispose()
})

$FolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Taranacak klasörü seçin"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Location $dialog.SelectedPath
    }
})

$ScanButton.Add_Click({ Rescan })
$RefreshButton.Add_Click({ Rescan })

$PauseButton.Add_Click({
    if ($script:isSelectedScanning) { return }
    if (-not $script:isScanning -or -not $script:pauseGate) { return }

    if (-not $script:isPaused) {
        $script:pauseGate.Reset()
        $script:isPaused = $true
        $PauseButton.Content = "Devam et"
        $LiveScanCurrentText.Text = "Tarama duraklatıldı"
        $scanAnimationTimer.Stop()
        Set-Status "Tarama duraklatıldı. Devam et dediğinde kaldığı yerden sürer." "#D97706"
    } else {
        $script:pauseGate.Set()
        $script:isPaused = $false
        $PauseButton.Content = "Duraklat"
        $scanAnimationTimer.Start()
        Set-Status "Taranıyor… Tarama devam ediyor." "#5B4CFF"
    }
})

$CancelButton.Add_Click({
    try {
        if ($script:isSelectedScanning -and $script:selectedScanCts) {
            try { if ($script:selectedScanPause) { $script:selectedScanPause.Set() } } catch {}
            $script:selectedScanCts.Cancel()
            $CancelButton.IsEnabled = $false
            Set-Status "Seçili öğe taraması iptal ediliyor…" "#D97706"
            Show-Notification "Seçili öğe taraması iptal ediliyor." "info"
            return
        }

        if ($script:isScanning -and $script:scanCts) {
            try { if ($script:pauseGate) { $script:pauseGate.Set() } } catch {}
            $script:scanCts.Cancel()
            $PauseButton.IsEnabled = $false
            $CancelButton.IsEnabled = $false
            Set-Status "Tarama iptal ediliyor…" "#D97706"
        }
    } catch {
        $raw = ""
        try { $raw = ($_ | Out-String) } catch {}
        Show-AppError "Tarama iptal hatası" $_.Exception $raw
    }
})

$SearchBox.Add_TextChanged({
    if ($script:isApplyingScanResult) { return }
    $filterTimer.Stop()
    $filterTimer.Start()
})



$SelectedRefreshButton.Add_Click({
    Start-SelectedRescan
})

$OpenButton.Add_Click({
    if (-not $script:selectedNode) { return }
    if ($script:selectedNode.IsFolder) {
        if (Test-Path -LiteralPath $script:selectedNode.Path) {
            Start-Process explorer.exe -ArgumentList "`"$($script:selectedNode.Path)`""
        }
    } else {
        if (Test-Path -LiteralPath $script:selectedNode.Path) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($script:selectedNode.Path)`""
        }
    }
})

$RenameButton.Add_Click({
    if (-not $script:selectedNode) { return }
    $item = $script:selectedNode

    if (Is-ProtectedPath $item.Path) {
        [System.Windows.MessageBox]::Show("Kritik sistem alanlarında yeniden adlandırma engellendi.", "DiskLens Premium V3.2.9", "OK", "Warning") | Out-Null
        return
    }
    if ($item.IsFolder -and (Is-DriveRoot $item.Path)) {
        [System.Windows.MessageBox]::Show("Disk kök klasörleri yeniden adlandırılamaz.", "DiskLens Premium V3.2.9", "OK", "Warning") | Out-Null
        return
    }

    $newName = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Yeni adı yazın:",
        "Yeniden adlandır",
        $item.Name
    )
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName -eq $item.Name) { return }

    $warning = ""
    if ($item.IsSystemLike) { $warning = "`n`n⚠ Bu öğe sistem/gizli özellik taşıyor. Değişiklik sorun çıkarabilir." }

    $confirm = [System.Windows.MessageBox]::Show(
        "Öğe yeniden adlandırılacak:`n`n$($item.Name)`n→ $newName$warning`n`nOnaylıyor musunuz?",
        "Değişikliği onayla",
        "YesNo",
        "Question"
    )
    if ($confirm -ne "Yes") { return }

    try {
        $parent = Split-Path -LiteralPath $item.Path -Parent
        $target = Join-Path $parent $newName
        if (Test-Path -LiteralPath $target) { throw "Bu isimde bir öğe zaten var." }
        Move-Item -LiteralPath $item.Path -Destination $target -ErrorAction Stop
        Set-Status "Öğe yeniden adlandırıldı; tarama yenileniyor." "#16A34A"; Show-Notification "Yeniden adlandırma başarılı." "success"
        Rescan
    } catch {
        Show-AppError "Yeniden adlandırma başarısız" $_.Exception
    }
})

$MoveButton.Add_Click({
    if (-not $script:selectedNode) { return }
    $item = $script:selectedNode

    if (Is-ProtectedPath $item.Path) {
        [System.Windows.MessageBox]::Show("Kritik sistem alanlarında taşıma engellendi.", "DiskLens Premium V3.2.9", "OK", "Warning") | Out-Null
        return
    }
    if ($item.IsFolder -and (Is-DriveRoot $item.Path)) {
        [System.Windows.MessageBox]::Show("Disk kök klasörleri taşınamaz.", "DiskLens Premium V3.2.9", "OK", "Warning") | Out-Null
        return
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Hedef klasörü seçin"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $warning = ""
    if ($item.IsSystemLike) { $warning = "`n`n⚠ Seçili öğe sistem/gizli özellik taşıyor." }

    $confirm = [System.Windows.MessageBox]::Show(
        "Öğe taşınacak:`n`n$($item.Path)`n→ $($dialog.SelectedPath)$warning`n`nBoyut: $($item.SizeText)`n`nOnaylıyor musunuz?",
        "Taşımayı onayla",
        "YesNo",
        "Question"
    )
    if ($confirm -ne "Yes") { return }

    try {
        $target = Join-Path $dialog.SelectedPath $item.Name
        if (Test-Path -LiteralPath $target) { throw "Hedefte aynı isimde öğe var." }
        Move-Item -LiteralPath $item.Path -Destination $target -ErrorAction Stop
        Set-Status "Öğe taşındı; tarama yenileniyor." "#16A34A"; Show-Notification "Taşıma başarılı." "success"
        Rescan
    } catch {
        Show-AppError "Taşıma başarısız" $_.Exception
    }
})

$DeleteButton.Add_Click({
    if (-not $script:selectedNode) { return }
    $item = $script:selectedNode

    # Actual drive roots stay protected. Warning/system items remain deletable.
    if ($item.IsFolder -and (Is-DriveRoot $item.Path)) {
        [System.Windows.MessageBox]::Show(
            "Gerçek disk kökü silinemez.",
            "DiskLens Premium V3.2.9",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $isRisky = ($item.IsSystemLike -or (Is-ProtectedPath $item.Path))

    $extra = ""
    if ($isRisky) {
        $extra = "`n`n⚠ UYARI: Bu öğe sistem/gizli veya kritik bir Windows/program alanında olabilir. Silinmesi Windows'un ya da bir uygulamanın çalışmasını bozabilir."
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Silmek istediğinizden emin misiniz?`n`n$($item.Path)`nBoyut: $($item.SizeText)$extra`n`nEvet derseniz öğe Geri Dönüşüm Kutusu'na gönderilecek.",
        "Silmek istediğinizden emin misiniz?",
        "YesNo",
        "Warning"
    )
    if ($confirm -ne "Yes") { return }

    try {
        if ($item.IsFolder) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $item.Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $item.Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
        }
        Update-DriveInfo
        Set-Status "Öğe Geri Dönüşüm Kutusu'na gönderildi; tarama yenileniyor." "#16A34A"; Show-Notification "Öğe Geri Dönüşüm Kutusu'na gönderildi." "success"
        Rescan
    } catch {
        Show-AppError "Silme başarısız" $_.Exception
    }
})

$window.Add_Closing({
    if ($script:isScanning -and $script:scanCts) {
        try { if ($script:pauseGate) { $script:pauseGate.Set() } } catch {}
        try { $script:scanCts.Cancel() } catch {}
    }

    if ($script:isSelectedScanning -and $script:selectedScanCts) {
        try { if ($script:selectedScanPause) { $script:selectedScanPause.Set() } } catch {}
        try { $script:selectedScanCts.Cancel() } catch {}
    }

    $pollTimer.Stop()
    $selectedScanTimer.Stop()
    $scanAnimationTimer.Stop()
    $filterTimer.Stop()
    Cleanup-SelectedScan
    Cleanup-Scan
})


try {
    $script:app.add_DispatcherUnhandledException({
        param($sender,$e)
        try {
            try { Show-AppError "Beklenmeyen arayüz hatası" $e.Exception } catch { }
            $e.Handled = $true
            try {
                if (-not $script:isScanning -and -not $script:isSelectedScanning) {
                    Set-ScanUiLock $false $false
                }
            } catch { }
        }
        catch {
            Write-BootstrapLog "Dispatcher hata işleyicisi başarısız" $_.Exception
        }
    })
}
catch {
    Write-BootstrapLog "Global WPF hata yakalayıcı bağlanamadı" $_.Exception
    [System.Windows.MessageBox]::Show(
        "Global hata yakalayıcı başlatılamadı.`n`n$($_.Exception.Message)`n`nAyrıntı: DiskLens_Hata.log",
        "DiskLens Premium V3.2.9",
        "OK",
        "Warning"
    ) | Out-Null
}


try {
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender,$e)
        try {
            $ex = $e.ExceptionObject
            Write-ErrorLog "Yakalanmamış işlem hatası" $ex
        } catch { }
    })
}
catch {
    Write-BootstrapLog "AppDomain hata yakalayıcı bağlanamadı" $_.Exception
}


function Test-DiskLensCore {
    $requiredFunctions = @(
        "Matches-Filter",
        "Sort-Folders",
        "Sort-Files",
        "Build-Indexes",
        "Rebuild-Tree",
        "Add-BranchChildren",
        "Start-SelectedRescan",
        "Merge-SelectedFolderScan",
        "Recalculate-FolderTotals",
        "Show-AppError",
        "Write-ErrorLog"
    )

    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($fn in $requiredFunctions) {
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            [void]$missing.Add($fn)
        }
    }

    if ($missing.Count -gt 0) {
        $detail = "Eksik çekirdek fonksiyonlar: " + ($missing -join ", ")
        Write-BootstrapLog "DiskLens self-check başarısız" ([System.Exception]::new($detail))
        [System.Windows.MessageBox]::Show(
            "DiskLens gerekli bileşenleri yükleyemedi.`n`n$detail`n`nHata ayrıntısı DiskLens_Hata.log dosyasına kaydedildi.",
            "DiskLens başlangıç kontrolü",
            "OK",
            "Error"
        ) | Out-Null
        return $false
    }

    return $true
}

if (-not (Test-DiskLensCore)) {
    exit 1
}

Apply-Theme $false
Apply-AppFont
$window.Add_ContentRendered({
    try {
        Show-Notification "DiskLens hazır. Hata oluşursa ekranda bildirim gösterilir ve DiskLens_Hata.log dosyasına kaydedilir." "info"
    } catch { }
})
[void]$window.ShowDialog()
