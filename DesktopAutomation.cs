using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;

public static class QuotaDesktop {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a,uint b,bool attach);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h,int cmd);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint f,bool i,uint a);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] input,int size);
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUT input);
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUT { public uint size,time; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type; public INPUTUNION data;}
  [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public KEYBD keyboard; [FieldOffset(0)] public MOUSE mouse; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBD {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
  [StructLayout(LayoutKind.Sequential)] struct MOUSE {public int x,y;public uint data,flags,time;public UIntPtr extra;}
  static IntPtr window; static uint lastInput;
  public static bool IsDesktopPath(string path) {return System.Text.RegularExpressions.Regex.IsMatch(path ?? "", @"\\(?:WindowsApps\\OpenAI\.Codex_[^\\]+\\app|OpenAI\\Codex\\app)\\(?:ChatGPT|Codex)\.exe$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);}
  static uint InputTime(){var i=new LASTINPUT{size=(uint)Marshal.SizeOf(typeof(LASTINPUT))};if(!GetLastInputInfo(ref i))throw new Exception("无法检测用户输入");return i.time;}
  public static void Check(){
    IntPtr desk=OpenInputDesktop(0,false,0x0100);if(desk==IntPtr.Zero)throw new Exception("桌面已锁定或不可交互");CloseDesktop(desk);
    if(GetForegroundWindow()!=window){uint pid;GetWindowThreadProcessId(GetForegroundWindow(),out pid);throw new Exception("前台窗口已改变，取消界面操作（目标="+window+"，实际="+GetForegroundWindow()+"，进程="+pid+"）");}
    if(InputTime()!=lastInput)throw new Exception("检测到其他键鼠输入，取消界面操作");
  }
  public static void Open(string id){
    SetProcessDPIAware();
    var matches=new List<Process>();foreach(var p in Process.GetProcesses()){try{if(p.MainWindowHandle!=IntPtr.Zero&&IsDesktopPath(p.MainModule.FileName))matches.Add(p);}catch{}}
    if(matches.Count!=1)throw new Exception("无法唯一识别 Codex 主窗口");
    window=matches[0].MainWindowHandle;
    IntPtr desk=OpenInputDesktop(0,false,0x0100);if(desk==IntPtr.Zero)throw new Exception("桌面已锁定");CloseDesktop(desk);
    Process.Start(new ProcessStartInfo("codex://threads/"+id){UseShellExecute=true});
    Thread.Sleep(600);uint foregroundPid;uint foregroundThread=GetWindowThreadProcessId(GetForegroundWindow(),out foregroundPid),ownThread=GetCurrentThreadId();
    bool attached=foregroundThread!=ownThread&&AttachThreadInput(ownThread,foregroundThread,true);
    try{ShowWindow(window,9);SetForegroundWindow(window);}finally{if(attached)AttachThreadInput(ownThread,foregroundThread,false);}
    Thread.Sleep(500);lastInput=InputTime();Check();
  }
  static AutomationElement Root(){Check();return AutomationElement.FromHandle(window);}
  public static AutomationElement[] Find(int type,string[] names){
    var all=Root().FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.LookupById(type)));
    return all.Cast<AutomationElement>().Where(e=>!e.Current.IsOffscreen&&e.Current.IsEnabled&&(names==null||names.Contains(e.Current.Name,StringComparer.OrdinalIgnoreCase))).ToArray();
  }
  public static string Text(AutomationElement e){object p;if(e.TryGetCurrentPattern(ValuePattern.Pattern,out p))return ((ValuePattern)p).Current.Value;
    if(e.TryGetCurrentPattern(TextPattern.Pattern,out p))return ((TextPattern)p).DocumentRange.GetText(-1).TrimEnd('\r','\n');
    throw new Exception("无法读取输入框内容");}
  public static AutomationElement One(int type,string[] names){var es=Find(type,names);if(es.Length!=1)throw new Exception("目标控件不唯一或不可见："+String.Join("/",names??new string[0])+" ("+es.Length+")");return es[0];}
  public static AutomationElement Message(string text){
    string expected=text.Replace("\r\n","\n").Replace('\r','\n').TrimEnd('\n');
    var nodes=Root().FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Text)).Cast<AutomationElement>().ToArray();
    var matches=new List<AutomationElement>();
    // Chromium exposes formatted or multiline messages as adjacent text nodes,
    // including a standalone newline node with no clickable rectangle.
    for(int i=0;i<nodes.Length;i++){
      if(nodes[i].Current.IsOffscreen||String.IsNullOrEmpty(nodes[i].Current.Name))continue;
      string combined="";
      for(int j=i;j<nodes.Length;j++){
        combined+=nodes[j].Current.Name.Replace("\r\n","\n").Replace('\r','\n');
        if(!expected.StartsWith(combined,StringComparison.Ordinal))break;
        if(combined==expected){matches.Add(nodes[i]);break;}
      }
    }
    if(matches.Count!=1)throw new Exception("末条消息不可见或内容不唯一，不能安全编辑。");
    return matches[0];
  }
  static AutomationElement Menu(string[] labels){for(int i=0;i<10;i++){var es=Find(50011,null).Where(e=>labels.Any(n=>e.Current.Name.Equals(n,StringComparison.OrdinalIgnoreCase)||e.Current.Name.StartsWith(n+" ",StringComparison.OrdinalIgnoreCase))).ToArray();if(es.Length==1)return es[0];Thread.Sleep(150);}throw new Exception("无法识别任务复制链接菜单（当前语言尚不支持）");}
  public static void Click(AutomationElement e){
    Check();var r=e.Current.BoundingRectangle;if(r.IsEmpty||r.Width<=0||r.Height<=0)throw new Exception("控件没有有效位置");
    SetCursorPos((int)(r.X+r.Width/2),(int)(r.Y+r.Height/2));
    var a=new INPUT[2];a[0].type=0;a[0].data.mouse.flags=2;a[1].type=0;a[1].data.mouse.flags=4;Send(a);Thread.Sleep(150);
  }
  public static void Hover(AutomationElement e){Check();var r=e.Current.BoundingRectangle;if(r.IsEmpty)throw new Exception("控件不可见");SetCursorPos((int)(r.X+r.Width/2),(int)(r.Y+r.Height/2));lastInput=InputTime();Thread.Sleep(350);}
  static void Send(INPUT[] a){if(SendInput((uint)a.Length,a,Marshal.SizeOf(typeof(INPUT)))!=a.Length)throw new Exception("键鼠输入不完整");lastInput=InputTime();}
  static INPUT Key(ushort key,bool up){var i=new INPUT{type=1};i.data.keyboard=new KEYBD{key=key,flags=up?2u:0u};return i;}
  public static void Chord(ushort key,bool ctrl,bool alt){Check();var a=new List<INPUT>();if(ctrl)a.Add(Key(0x11,false));if(alt)a.Add(Key(0x12,false));a.Add(Key(key,false));a.Add(Key(key,true));if(alt)a.Add(Key(0x12,true));if(ctrl)a.Add(Key(0x11,true));Send(a.ToArray());Thread.Sleep(120);}
  public static void Type(string text){
    Check();var a=new List<INPUT>();
    foreach(char ch in text.Replace("\r\n","\n").Replace('\r','\n')){
      // Unicode LF is ignored by Chromium's editor. Shift+Enter inserts a line
      // break without triggering the application's Enter-to-send shortcut.
      if(ch=='\n'){a.Add(Key(0x10,false));a.Add(Key(0x0D,false));a.Add(Key(0x0D,true));a.Add(Key(0x10,true));}
      else{var i=new INPUT{type=1};i.data.keyboard=new KEYBD{scan=ch,flags=4};a.Add(i);i.data.keyboard.flags=6;a.Add(i);}
    }
    Send(a.ToArray());Thread.Sleep(250);
  }
  static T Clip<T>(Func<T> operation){for(int i=0;;i++){try{return operation();}catch(ExternalException){if(i>=20)throw;Thread.Sleep(50);}}}
  public static void AssertThread(string id){
    Check();var old=Clip(()=>Clipboard.GetDataObject());var saved=new DataObject();
    if(old!=null)foreach(string f in old.GetFormats(false)){object value=old.GetData(f,false);
      if(value is MemoryStream)value=new MemoryStream(((MemoryStream)value).ToArray());
      else if(value is System.Drawing.Bitmap)value=((System.Drawing.Bitmap)value).Clone();
      else if(value!=null && !(value is string) && !(value is string[]) && !(value is byte[]))throw new Exception("无法安全保存剪贴板格式："+f);
      if(value!=null)saved.SetData(f,false,value);
    }
    string marker="quota-check-"+Guid.NewGuid();string link="";
    try{Clip(()=>{Clipboard.SetText(marker);return true;});
      Click(One(50000,new[]{"聊天操作","Chat actions","Thread actions","對話操作"}));
      Click(Menu(new[]{"复制","Copy","複製"}));
      Click(Menu(new[]{"复制深度链接","Copy deep link","Copy chat link","Copy thread link","複製深層連結"}));
      for(int i=0;i<20;i++){Thread.Sleep(100);Check();link=Clip(()=>Clipboard.ContainsText()?Clipboard.GetText():"");if(link!=marker)break;}}
    finally{if(old==null)Clip(()=>{Clipboard.Clear();return true;});else Clipboard.SetDataObject(saved,true,20,50);}
    if(!String.Equals(link.Trim().TrimEnd('/'),"codex://threads/"+id,StringComparison.OrdinalIgnoreCase))throw new Exception("当前任务 ID 核验失败（剪贴板"+(link==marker?"未更新":"已更新但链接不匹配")+"）");
  }
}
