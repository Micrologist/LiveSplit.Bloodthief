state("bloodthief"){}

startup
{
    vars.Log = (Action<object>)((output) => print("[Bloodthief ASL] " + output));

    vars.UpdateSpeedometer = (Action<double>)((speed) =>
    {
        var id = "Speed";
        var text = speed.ToString("0.0") + " m/s";
        var textSettings = timer.Layout.Components.Where(x => x.GetType().Name == "TextComponent").Select(x => x.GetType().GetProperty("Settings").GetValue(x, null));
        var textSetting = textSettings.FirstOrDefault(x => (x.GetType().GetProperty("Text1").GetValue(x, null) as string) == id);
        if (textSetting == null)
        {
            var textComponentAssembly = Assembly.LoadFrom("Components\\LiveSplit.Text.dll");
            var textComponent = Activator.CreateInstance(textComponentAssembly.GetType("LiveSplit.UI.Components.TextComponent"), timer);
            timer.Layout.LayoutComponents.Add(new LiveSplit.UI.Components.LayoutComponent("LiveSplit.Text.dll", textComponent as LiveSplit.UI.Components.IComponent));
            textSetting = textComponent.GetType().GetProperty("Settings", BindingFlags.Instance | BindingFlags.Public).GetValue(textComponent, null);
            textSetting.GetType().GetProperty("Text1").SetValue(textSetting, id);
        }
        if (textSetting != null)
        {
            textSetting.GetType().GetProperty("Text2").SetValue(textSetting, text);
        }
    });

    if (timer.CurrentTimingMethod == TimingMethod.RealTime)
    {
        DialogResult dbox = MessageBox.Show(timer.Form,
            "Bloodthief uses in-game time.\nWould you like to switch LiveSplit's timing method to that?",
            "LiveSplit | Bloodthief ASL",
            MessageBoxButtons.YesNo);

        if (dbox == DialogResult.Yes)
        {
            timer.CurrentTimingMethod = TimingMethod.GameTime;
        }
    }

    settings.Add("speedometer", true, "Show speed readout");
    settings.Add("checkpointSplit", true, "Split when reaching a checkpoint");
}

init
{
    vars.SceneTree = vars.GameManager = vars.EndLevelScreen = IntPtr.Zero;
    current.igt = old.igt = -1;
    current.checkpointNum = old.checkpointNum = 0;
    current.scene = old.scene = "MainScreen";
    current.levelFinished = old.levelFinished = false;

    //I don't ACTUALLY know how StringNames work, but this seems to do the job
    //See https://docs.godotengine.org/en/stable/classes/class_stringname.html
    vars.ReadStringName = (Func<IntPtr, string>) ((ptr) => {
        var output = "";
        var charPtr = game.ReadValue<IntPtr>((IntPtr)ptr + 0x10);
        
        while(game.ReadValue<int>((IntPtr)charPtr) != 0)
        {
            output += game.ReadValue<char>(charPtr);
            charPtr += 0x4;
        }
        
        return output;
    });

    //Our "entry" into the hierarchy is Godot's SceneTree object. See https://docs.godotengine.org/en/stable/classes/class_scenetree.html#class-scenetree
    //We are scanning for a piece of code that accesses the static pointer to the singleton instance of SceneTree
    //--- bloodthief_v0.01.exe+3F01F8 - 4C 8B 35 F1C3FA02     - mov r14,[bloodthief_v0.01.exe+339C5F0]
    //"4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74 7E E8 ?? ?? ?? ?? 49 8B CE 48 8B F0 48 8B 10 48 8B BA"
    var scn = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);
    var sceneTreeTrg = new SigScanTarget(3, "4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74") { OnFound = (p, s, ptr) => ptr + 0x4 + game.ReadValue<int>(ptr) };
    var sceneTreePtr = scn.Scan(sceneTreeTrg);

    if(sceneTreePtr == IntPtr.Zero)
    {
        throw new Exception("SceneTree not found - trying again!");
    }

    //Follow the pointer
    vars.SceneTree = game.ReadValue<IntPtr>((IntPtr)sceneTreePtr); 

    //SceneTree.root
    var rootWindow = game.ReadValue<IntPtr>((IntPtr)vars.SceneTree+0x348);

    //We are starting from the rootwindow node, its children are the scene root nodes
    var childCount = game.ReadValue<int>((IntPtr)rootWindow + 0x1B8);
    var childArrayPtr = game.ReadValue<IntPtr>((IntPtr)rootWindow + 0x1C0);

    //Iterating through all scene root nodes to find the GameManager and EndLevelScreen nodes
    //Caching here only works because the nodes aren't ever destroyed/created at runtime
    for (int i = 0; i < childCount; i++)
    {
        var child = game.ReadValue<IntPtr>(childArrayPtr + (0x8 * i));
        var childName = vars.ReadStringName(game.ReadValue<IntPtr>(child + 0x218));

        if(childName == "GameManager")
        {
            vars.GameManager = child;
        }
        else if(childName == "EndLevelScreen")
        {  
            vars.EndLevelScreen = child;
        }
    }

    if(vars.GameManager == IntPtr.Zero || vars.EndLevelScreen == IntPtr.Zero)
    {
        //This should only happen during game boot
        throw new Exception("GameManager/EndLevelScreen not found - trying again!");
    }

    //This grabs the GDScriptInstance attached to the GameManager Node
    vars.GameManager = game.ReadValue<IntPtr>((IntPtr)vars.GameManager + 0x68);

    //Vector<Variant> GDScriptInstance.members
    var gameManagerMemberArray = game.ReadValue<IntPtr>((IntPtr)vars.GameManager + 0x28);

    //The hardcoded offsets for the members will break if the underlying GDScript is modified in an update
    //There is a way to programmatically get members by name, but I'm too lazy for now
    vars.Watchers = new MemoryWatcherList
    {
        //GameManager.total_game_seconds
        new MemoryWatcher<double>(new DeepPointer(gameManagerMemberArray + 0xE0)) { Name = "total_game_seconds"},
        //GameManager.current_checkpoint
        new MemoryWatcher<int>(new DeepPointer(gameManagerMemberArray + 0x2603)) { Name = "current_checkpoint"},
        //GameManager.player
        new MemoryWatcher<IntPtr>(new DeepPointer(gameManagerMemberArray + 0x28)) { Name = "player"},

        //EndLevelScreen.visible (EndLevelScreen is a CanvasLayer Node)
        new MemoryWatcher<bool>(new DeepPointer(vars.EndLevelScreen + 0x444)) { Name = "level_end_screen_visible"}
    };

    vars.Log("gameManagerMemberArray at 0x"+gameManagerMemberArray.ToString("X16"));
}

update
{
    vars.Watchers.UpdateAll(game);
    current.igt = (vars.Watchers["total_game_seconds"].Current - 7.2) / 13.3; // deobfuscating the timer
    current.checkpointNum = vars.Watchers["current_checkpoint"].Current;
    current.levelFinished = vars.Watchers["level_end_screen_visible"].Current;

    //SceneTree.current_scene
    var currentSceneNode = game.ReadValue<IntPtr>((IntPtr)vars.SceneTree + 0x438);
    var newScene = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)currentSceneNode + 0x218));
    current.scene = String.IsNullOrEmpty(newScene) ? old.scene : newScene;
    current.inMainMenu = current.scene == "MainScreen";
    
    if(settings["speedometer"])
    {
        var player = (IntPtr)vars.Watchers["player"].Current;
        var xVel = game.ReadValue<float>(player + 0x618);
        var zVel = game.ReadValue<float>(player + 0x620);
        current.speed = Math.Sqrt((xVel * xVel) + (zVel * zVel));
        vars.UpdateSpeedometer(current.speed);
    }
    
}

isLoading
{
    return true;
}

gameTime
{
    return TimeSpan.FromSeconds(current.igt);
}

split
{
    return (settings["checkpointSplit"] && current.checkpointNum > old.checkpointNum)
        || (current.levelFinished && !old.levelFinished);
}

start
{
    return (current.igt > 0 && old.igt <= 0)
        && !current.inMainMenu;
}

reset
{
    return current.igt < old.igt - 0.1;
}