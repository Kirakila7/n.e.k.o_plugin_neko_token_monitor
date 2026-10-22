// Remember only windows this widget hid; never guess which invisible windows to show.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

internal sealed class WindowOwnership {
    internal delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr window, ref Placement placement);
    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr window, ref Placement placement);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] struct ProcessEntry {
        public uint size, usage, pid; public IntPtr heap; public uint module, threads, parent;
        public int priority; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string exe;
    }
    [StructLayout(LayoutKind.Sequential)] public struct XY { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] public struct Box { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Placement {
        public int length,flags,showCmd; public XY min,max; public Box normal;
    }
    public sealed class Saved {
        public long handle, started; public uint pid; public Placement placement; public string session;
    }
    readonly Dictionary<long,Saved> hidden=new Dictionary<long,Saved>();
    readonly string journal;
    readonly JavaScriptSerializer json=new JavaScriptSerializer();
    internal int Count=>hidden.Count;
    internal WindowOwnership(string directory) {
        Directory.CreateDirectory(directory);journal=Path.Combine(directory,"windows-hidden.json");
        if(!File.Exists(journal))return;
        // Refuse to overwrite a damaged recovery journal and risk losing its entries.
        if(new FileInfo(journal).Length>256*1024)throw new IOException("窗口恢复记录过大");
        foreach(var row in json.Deserialize<List<Saved>>(File.ReadAllText(journal,Encoding.UTF8))) {
            hidden[row.handle]=row;
            if(Guid.TryParse(row.session,out Guid id))AtomicWrite(Path.Combine(directory,"closed-"+id.ToString()+".json"),json.Serialize(new {session_id=id.ToString()}));
        }
        Restore();
        if(hidden.Count>0)throw new IOException("上次隐藏的 NEKO 窗口尚未恢复");
    }
    internal static void AtomicWrite(string path,string value) {
        string temporary=path+".tmp";
        using(var stream=new FileStream(temporary,FileMode.Create,FileAccess.Write,FileShare.None)) {
            var data=new UTF8Encoding(false).GetBytes(value);stream.Write(data,0,data.Length);stream.Flush(true);
        }
        if(File.Exists(path))File.Replace(temporary,path,null);else File.Move(temporary,path);
    }
    void Save()=>AtomicWrite(journal,json.Serialize(hidden.Values.ToArray()));
    static long Started(uint pid) {try{return Process.GetProcessById((int)pid).StartTime.ToUniversalTime().Ticks;}catch{return 0;}}
    static HashSet<uint> Tree(Dictionary<uint,ProcessEntry> all,HashSet<uint> roots) {
        bool changed;do {changed=false;foreach(var pair in all)if(roots.Contains(pair.Value.parent)&&roots.Add(pair.Key))changed=true;}while(changed);
        return roots;
    }
    internal static HashSet<uint> HostProcesses() {
        var all=new Dictionary<uint,ProcessEntry>();var hosts=new HashSet<uint>();
        var handle=CreateToolhelp32Snapshot(2,0);if(handle==new IntPtr(-1))return hosts;
        try {var entry=new ProcessEntry {size=(uint)Marshal.SizeOf(typeof(ProcessEntry))};
            if(Process32First(handle,ref entry))do {all[entry.pid]=entry;}while(Process32Next(handle,ref entry));
        }finally {CloseHandle(handle);}
        foreach(var pair in all) {
            var name=Path.GetFileNameWithoutExtension(pair.Value.exe).Replace(".","").Replace("-","").Replace("_","").Replace(" ","").ToLowerInvariant();
            if(name=="neko"||name=="nekodesktop")hosts.Add(pair.Key);
        }
        Tree(all,hosts);
        // NEKO launches this plugin, so our WebView2 processes are descendants too.
        hosts.ExceptWith(Tree(all,new HashSet<uint>{(uint)Process.GetCurrentProcess().Id}));
        return hosts;
    }
    internal bool Hide(string session) {
        var hosts=HostProcesses();bool ok=true;
        foreach(var row in hidden.Values.ToArray())if(!SameOwner(row))hidden.Remove(row.handle);
        Save();
        EnumWindows((window,data)=> {
            GetWindowThreadProcessId(window,out uint pid);
            if(!hosts.Contains(pid)||!IsWindowVisible(window))return true;
            long key=window.ToInt64();
            if(!hidden.ContainsKey(key)) {
                var placement=new Placement {length=Marshal.SizeOf(typeof(Placement))};long started=Started(pid);
                if(started==0||!GetWindowPlacement(window,ref placement)){ok=false;return true;}
                hidden[key]=new Saved {handle=key,pid=pid,started=started,placement=placement,session=session};
                try {Save();}catch {hidden.Remove(key);ok=false;return true;}
            }
            ShowWindow(window,0);if(IsWindowVisible(window))ok=false;
            return true;
        },IntPtr.Zero);
        foreach(var row in hidden.Values)if(SameOwner(row)&&IsWindowVisible(new IntPtr(row.handle)))ok=false;
        return hidden.Count>0&&ok;
    }
    static bool SameOwner(Saved row) {
        var handle=new IntPtr(row.handle);if(!IsWindow(handle))return false;
        GetWindowThreadProcessId(handle,out uint pid);return pid==row.pid&&Started(pid)==row.started;
    }
    internal bool Restore() {
        foreach(var row in hidden.Values.ToArray()) {
            if(!SameOwner(row)){hidden.Remove(row.handle);continue;}
            var placement=row.placement;placement.length=Marshal.SizeOf(typeof(Placement));
            if(placement.showCmd==0)placement.showCmd=1;
            if(SetWindowPlacement(new IntPtr(row.handle),ref placement)&&IsWindowVisible(new IntPtr(row.handle)))hidden.Remove(row.handle);
        }
        Save();return hidden.Count==0;
    }
}
