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

    settings.Add("endlevelSplit", true, "Split when finishing a level");
    settings.Add("checkpointSplit", false, "Split when reaching a checkpoint");
    settings.Add("levelOneReset", true, "Reset timer when restarting level 1");
    settings.Add("ilMode", false, "Reset timer when restarting any level (IL Mode)");
    settings.Add("speedometer", false, "Show speed readout");
}

init
{
    vars.SceneTree = vars.GameManager = vars.EndLevelScreen = IntPtr.Zero;
    vars.AccIgt = 0;
    vars.LevelOneCompleted = false;
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

    //Godot 4.4 offsets
    vars.ROOT_WINDOW_OFFSET = 0x3A8;
    vars.CHILD_ARRAY_OFFSET = 0x1C8;
    vars.NODE_NAME_OFFSET = 0x228;
    vars.CL_VISIBLE_OFFSET = 0x454;
    vars.CURRENT_SCENE_OFFSET = 0x498;
    vars.PLAYER_VEL_OFFSET = 0x648;

    //Our "entry" into the hierarchy is Godot's SceneTree object. See https://docs.godotengine.org/en/stable/classes/class_scenetree.html#class-scenetree
    //We are scanning for a piece of code that accesses the static pointer to the singleton instance of SceneTree
    //--- bloodthief_v0.01.exe+3F01F8 - 4C 8B 35 F1C3FA02     - mov r14,[bloodthief_v0.01.exe+339C5F0]
    //"4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74 7E E8 ?? ?? ?? ?? 49 8B CE 48 8B F0 48 8B 10 48 8B BA"
    var scn = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);
    var sceneTreeTrg = new SigScanTarget(3, "4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74 7E") { OnFound = (p, s, ptr) => ptr + 0x4 + game.ReadValue<int>(ptr) };
    var sceneTreePtr = scn.Scan(sceneTreeTrg);

    if(sceneTreePtr == IntPtr.Zero)
    {
        //Check if the 4.3 signature works instead
        sceneTreeTrg = new SigScanTarget(3, "4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74") { OnFound = (p, s, ptr) => ptr + 0x4 + game.ReadValue<int>(ptr) };
        sceneTreePtr = scn.Scan(sceneTreeTrg);
        if(sceneTreePtr == IntPtr.Zero)
        {
            throw new Exception("SceneTree not found - trying again!");
        }
        else
        {
            //Godot 4.3 offsets
            vars.ROOT_WINDOW_OFFSET = 0x348;
            vars.CHILD_ARRAY_OFFSET = 0x1B8;
            vars.NODE_NAME_OFFSET = 0x218;
            vars.CL_VISIBLE_OFFSET = 0x444;
            vars.CURRENT_SCENE_OFFSET = 0x438;
            vars.PLAYER_VEL_OFFSET = 0x618;
        }
    }

    //Follow the pointer
    vars.SceneTree = game.ReadValue<IntPtr>((IntPtr)sceneTreePtr); 

    //SceneTree.root
    var rootWindow = game.ReadValue<IntPtr>((IntPtr)(vars.SceneTree + vars.ROOT_WINDOW_OFFSET));

    //We are starting from the rootwindow node, its children are the scene root nodes
    var childCount = game.ReadValue<int>((IntPtr)(rootWindow + vars.CHILD_ARRAY_OFFSET));
    var childArrayPtr = game.ReadValue<IntPtr>((IntPtr)(rootWindow + vars.CHILD_ARRAY_OFFSET + 0x8));

    //Iterating through all scene root nodes to find the GameManager and EndLevelScreen nodes
    //Caching here only works because the nodes aren't ever destroyed/created at runtime
    for (int i = 0; i < childCount; i++)
    {
        var child = game.ReadValue<IntPtr>(childArrayPtr + (0x8 * i));
        var childName = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)(child + vars.NODE_NAME_OFFSET)));

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
        new MemoryWatcher<int>(new DeepPointer(gameManagerMemberArray + 0x260)) { Name = "current_checkpoint"},
        //GameManager.player
        new MemoryWatcher<IntPtr>(new DeepPointer(gameManagerMemberArray + 0x28)) { Name = "player"},

        //EndLevelScreen.visible (EndLevelScreen is a CanvasLayer Node)
        new MemoryWatcher<bool>(new DeepPointer(vars.EndLevelScreen + vars.CL_VISIBLE_OFFSET)) { Name = "level_end_screen_visible"}
    };
}

update
{
    vars.Watchers.UpdateAll(game);

    current.checkpointNum = vars.Watchers["current_checkpoint"].Current;
    current.levelFinished = vars.Watchers["level_end_screen_visible"].Current;

    //SceneTree.current_scene
    var currentSceneNode = game.ReadValue<IntPtr>((IntPtr)(vars.SceneTree + vars.CURRENT_SCENE_OFFSET));
    var newScene = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)(currentSceneNode + vars.NODE_NAME_OFFSET)));
    current.scene = String.IsNullOrEmpty(newScene) ? old.scene : newScene;
    current.inMainMenu = current.scene == "MainScreen";

    current.igt = current.inMainMenu ? 0f : ((vars.Watchers["total_game_seconds"].Current - 7.2) / 13.3);
    current.igt = Math.Floor(current.igt * 1000) / 1000;

    if(current.levelFinished && current.scene == "JakePractice2")
    {
        vars.LevelOneCompleted = true;
    }

    if(!settings["ilMode"] && current.igt < old.igt && old.scene != "MainScreen")
    {
        vars.AccIgt += old.igt;
        vars.Log("Accumulated "+old.igt.ToString("0.00")+" seconds of igt on "+old.scene);
    }

    if(settings["speedometer"])
    {
        var player = (IntPtr)vars.Watchers["player"].Current;
        var xVel = game.ReadValue<float>((IntPtr)(player + vars.PLAYER_VEL_OFFSET));
        var zVel = game.ReadValue<float>((IntPtr)(player + vars.PLAYER_VEL_OFFSET + 0x8));
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
    return TimeSpan.FromSeconds(vars.AccIgt + current.igt);
}

split
{
    return (settings["checkpointSplit"] && current.checkpointNum > old.checkpointNum)
        || (settings["endlevelSplit"] && current.levelFinished && !old.levelFinished);
}

start
{
    return (current.igt > 0 && old.igt <= 0)
        && !current.inMainMenu;
}

onStart
{
    vars.AccIgt = 0f;
    vars.LevelOneCompleted = false;
}

reset
{
    return (
        (current.igt < old.igt && !current.inMainMenu) && (
            settings["ilMode"] || 
            (settings["levelOneReset"] &&
            !vars.LevelOneCompleted &&
            current.scene == "JakePractice2" && 
            !old.levelFinished && !current.levelFinished)
        )
    ) || (
        settings["levelOneReset"] && 
        current.scene == "JakePractice2" && 
        old.scene == "MainScreen"
    );
}

exit
{
    timer.IsGameTimePaused = true;
}