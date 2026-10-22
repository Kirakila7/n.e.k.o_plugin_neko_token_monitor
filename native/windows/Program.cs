using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal sealed class Camera : Form {
    internal readonly PictureBox picture=new PictureBox {Dock=DockStyle.Fill,SizeMode=PictureBoxSizeMode.Zoom};
    internal Camera() {
        Text="猫粮摄像头开关";FormBorderStyle=FormBorderStyle.None;ClientSize=new Size(88,88);
        BackColor=Color.Magenta;TransparencyKey=Color.Magenta;TopMost=true;ShowInTaskbar=false;
        StartPosition=FormStartPosition.Manual;Controls.Add(picture);
    }
    protected override bool ShowWithoutActivation=>true;
    protected override CreateParams CreateParams {get {var p=base.CreateParams;p.ExStyle|=0x08000000|0x80;return p;}}
}
class CatFood : Form {
    readonly WebView2 web=new WebView2();
    readonly Timer life=new Timer {Interval=500};
    readonly JavaScriptSerializer json=new JavaScriptSerializer();
    readonly int parent;
    readonly string baseUrl,stopFile,recordingDir;
    readonly bool smoke,launcherOnly;
    readonly WindowOwnership windows;
    readonly Camera camera=new Camera();
    readonly Image on,off;
    bool recording,closing,ready,toggleBusy,hiding,confirmed;
    string session;
    int generation;
    DateTime started;
    Point mouse,origin;
    bool dragging;
    RectangleF? bubble;
    static string Option(string[] args,string name,string fallback) {int i=Array.IndexOf(args,name);return i>=0&&i+1<args.Length?args[i+1]:fallback;}
    public CatFood(string[] args) {
        parent=int.Parse(args[0]);baseUrl=args[1].TrimEnd('/');stopFile=Path.GetFullPath(args[2]);
        var uri=new Uri(baseUrl);if(uri.Scheme!="http"||uri.Host!="127.0.0.1"||uri.AbsolutePath!="/"||!string.IsNullOrEmpty(uri.Query))throw new ArgumentException("无效的本机服务地址");
        recordingDir=Option(args,"--recording-dir",Path.GetDirectoryName(stopFile));
        windows=new WindowOwnership(recordingDir);
        smoke=Array.IndexOf(args,"--smoke")>=0;launcherOnly=Array.IndexOf(args,"--launcher-only")>=0;
        Text="猫粮";FormBorderStyle=FormBorderStyle.None;ClientSize=new Size(420,500);TopMost=true;
        BackColor=Color.Magenta;TransparencyKey=Color.Magenta;ShowInTaskbar=false;
        StartPosition=FormStartPosition.Manual;var area=Screen.PrimaryScreen.WorkingArea;Location=new Point(area.Right-460,area.Bottom-520);
        string assets=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","..","static","launcher"));
        if(!Directory.Exists(assets))assets=Path.Combine(Environment.CurrentDirectory,"static","launcher");
        if(File.Exists(Path.Combine(assets,"yui-camera-on.png")))on=Image.FromFile(Path.Combine(assets,"yui-camera-on.png"));
        if(File.Exists(Path.Combine(assets,"yui-camera-off.png")))off=Image.FromFile(Path.Combine(assets,"yui-camera-off.png"));
        camera.picture.MouseClick+=async(s,e)=> {
            if(!ready||toggleBusy)return;
            if(e.Button==MouseButtons.Right){Show();await Script("window.openAccount&&window.openAccount()");return;}
            toggleBusy=true;UpdateCamera();await Script("window.catfoodToggleMonitoring&&window.catfoodToggleMonitoring()");
        };
        LocationChanged+=(s,e)=>PositionCamera();SizeChanged+=(s,e)=>PositionCamera();
        web.Dock=DockStyle.Fill;web.DefaultBackgroundColor=Color.Transparent;Controls.Add(web);
        Shown+=async(s,e)=>await Initialize();
        life.Tick+=(s,e)=> {
            try {if(Process.GetProcessById(parent).HasExited||File.Exists(stopFile)){Close();return;}}
            catch {Close();return;}
            if(recording)HideOriginal();else if(windows.Count>0)try {windows.Restore();}catch(Exception error){Log(error);}
        };life.Start();
        FormClosing+=(s,e)=> {
            closing=true;generation++;recording=false;
            try {PersistEnd();windows.Restore();}catch(Exception error){Log(error);}
            life.Stop();camera.Close();
        };
        FormClosed+=(s,e)=>{on?.Dispose();off?.Dispose();};
    }
    protected override bool ShowWithoutActivation=>true;
    bool Trusted(string source)=>Uri.TryCreate(source,UriKind.Absolute,out Uri u)&&u.GetLeftPart(UriPartial.Authority)==baseUrl&&u.AbsolutePath=="/widget";
    async Task Initialize() {
        try {
            var folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NekoCatFood","WebView2");
            var env=await CoreWebView2Environment.CreateAsync(null,folder);
            await web.EnsureCoreWebView2Async(env);
            web.CoreWebView2.Settings.AreDevToolsEnabled=false;
            web.CoreWebView2.Settings.AreDefaultContextMenusEnabled=false;
            web.CoreWebView2.Settings.AreHostObjectsAllowed=false;
            web.CoreWebView2.NewWindowRequested+=(a,b)=>b.Handled=true;
            web.CoreWebView2.NavigationStarting+=(a,b)=>{if(!Trusted(b.Uri))b.Cancel=true;};
            web.CoreWebView2.WebMessageReceived+=(a,b)=> {
                if(!Trusted(b.Source))return;
                try {Action(json.DeserializeObject(b.WebMessageAsJson));}catch(Exception error){Log(error);}
            };
            web.CoreWebView2.ProcessFailed+=(a,b)=>{Log(new IOException("WebView2 进程已退出："+b.ProcessFailedKind));Close();};
            await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("window.catfoodHasLauncher=true;window.catfoodLauncherOnly="+(launcherOnly?"true":"false")+";");
            web.CoreWebView2.NavigationCompleted+=(a,b)=> {
                if(smoke){File.WriteAllText(stopFile+".ready",b.IsSuccess?"ready":"failed");Close();return;}
                if(!b.IsSuccess){Log(new IOException("猫粮页面加载失败："+b.WebErrorStatus));Close();return;}
                ready=true;PositionCamera();UpdateCamera();camera.Show();if(launcherOnly)Hide();
            };
            web.Source=new Uri(baseUrl+"/widget");
        }catch(Exception error) {
            Log(error);
            if(!smoke)MessageBox.Show("猫粮窗口未能启动："+error.GetType().Name+"\n请确认已安装 Microsoft Edge WebView2 Runtime。详细原因保存在插件数据目录的 widget-native.log。","猫粮");
            Close();
        }
    }
    static void Log(Exception error)=>Console.Error.WriteLine(DateTime.UtcNow.ToString("o")+" "+error.GetType().Name+": "+error.Message);
    async Task Script(string value) {try {if(!closing&&web.CoreWebView2!=null)await web.CoreWebView2.ExecuteScriptAsync(value);}catch(Exception error){Log(error);}}
    void PositionCamera() {
        if(camera.IsDisposed)return;
        float scale=web.Width>0?(float)ClientSize.Width/web.Width:1;
        var r=bubble??new RectangleF(80,16,230,100);
        var point=web.PointToScreen(new Point((int)((r.Right+8)*scale),(int)(r.Top*scale)));
        var area=Screen.FromPoint(point).WorkingArea;
        camera.Location=new Point(Math.Max(area.Left,Math.Min(area.Right-camera.Width,point.X)),Math.Max(area.Top,Math.Min(area.Bottom-camera.Height,point.Y)));
    }
    void UpdateCamera() {
        camera.picture.Image=recording&&confirmed?on:off;
        camera.picture.Enabled=ready&&!toggleBusy&&(!recording||confirmed);
        camera.picture.AccessibleName=recording&&confirmed?"猫粮监控中，点击恢复原版 YUI":"猫粮监控未运行，点击进入监控";
    }
    async void HideOriginal() {
        if(hiding||closing||!recording)return;
        hiding=true;int token=generation;string activeSession=session;
        try {
            bool ok=windows.Hide(session);
            if(!ok&&!confirmed&&(DateTime.UtcNow-started).TotalSeconds<8)return;
            if(token!=generation||!recording||closing)return;
            confirmed=ok;
            if(ok)Show();else {windows.Restore();Hide();}
            UpdateCamera();
            await Script("window.catfoodNativeState&&window.catfoodNativeState("+json.Serialize(new {active=true,ok,paused=false,targets=windows.Count,session_id=activeSession,reason=ok?null:"hide_unconfirmed"})+")");
        }catch(Exception error) {Log(error);End();}
        finally {hiding=false;}
    }
    void PersistEnd() {
        if(Guid.TryParse(session,out Guid id))WindowOwnership.AtomicWrite(Path.Combine(recordingDir,"closed-"+id.ToString()+".json"),json.Serialize(new {session_id=id.ToString()}));
    }
    void End() {
        generation++;recording=false;confirmed=false;toggleBusy=false;
        try {PersistEnd();windows.Restore();}catch(Exception error){Log(error);}
        session=null;Hide();UpdateCamera();
    }
    void Action(object message) {
        var body=message as Dictionary<string,object>;
        string action=message as string;
        if(body!=null&&body.TryGetValue("action",out object name))action=name as string;
        string requested=body!=null&&body.TryGetValue("session_id",out object identifier)?identifier as string:null;
        switch(action) {
        case "recordStart":
            if(requested!=null&&!Guid.TryParse(requested,out _))return;
            if(recording&&requested==session)return;
            if(recording)End();
            session=requested;generation++;recording=true;confirmed=false;started=DateTime.UtcNow;UpdateCamera();HideOriginal();break;
        case "recordEnd":if(requested!=null&&requested!=session)return;End();break;
        case "hide":if(!recording)Hide();break;
        case "toggleSettled":toggleBusy=false;UpdateCamera();break;
        case "launcherLayout":
            if(body!=null&&body.TryGetValue("rect",out object raw)&&raw is Dictionary<string,object> r) {
                float x=Convert.ToSingle(r["x"]),y=Convert.ToSingle(r["y"]),w=Convert.ToSingle(r["width"]),h=Convert.ToSingle(r["height"]);
                if(!float.IsNaN(x+y+w+h)&&!float.IsInfinity(x+y+w+h)&&w>0&&h>0&&w<2000&&h<2000){bubble=new RectangleF(x,y,w,h);PositionCamera();}
            }break;
        case "dragStart":mouse=Cursor.Position;origin=Location;dragging=true;break;
        case "dragEnd":dragging=false;break;
        case "dragMove":if(dragging)Location=new Point(origin.X+Cursor.Position.X-mouse.X,origin.Y+Cursor.Position.Y-mouse.Y);break;
        }
    }
    [STAThread] static int Main(string[] args) {
        Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
        if(args.Length==1&&args[0]=="--fixture") {
            var host=new Form {Text="NEKO lifecycle fixture",StartPosition=FormStartPosition.Manual,Location=new Point(40,60)};
            host.Shown+=(s,e)=>new Form {Text="NEKO chat fixture",StartPosition=FormStartPosition.Manual,Location=new Point(380,90)}.Show();Application.Run(host);return 0;
        }
        if(args.Length<3)return 2;
        try {Application.Run(new CatFood(args));return 0;}catch(Exception error){Log(error);return 1;}
    }
}
