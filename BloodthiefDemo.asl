state("bloodthief"){}

startup
{
    vars.Log = (Action<object>)((output) => print("[Bloodthief ASL] " + output));

    vars.SetTextComponent = (Action<string, string>)((id, text) =>
	{
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
            textSetting.GetType().GetProperty("Text2").SetValue(textSetting, text);
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
    settings.Add("ilMode", false, "Always reset when restarting level (IL Mode)");
    settings.Add("aprilComp", true, "Subtract 0.9 seconds for every kill (April Competition)"); 
    settings.Add("enemyCounter", false, "Show enemy kill counter", "aprilComp");
    settings.Add("speedometer", false, "Show speed readout");

    // Godot 4.4 Offsets
    // SceneTree
    vars.SCENETREE_ROOT_WINDOW_OFFSET        = 0x03A8; // Window*                           SceneTree::root
    vars.SCENETREE_CURRENT_SCENE_OFFSET      = 0x0498; // Node*                             SceneTree::current_scene

    // Node / Object
    vars.OBJECT_SCRIPT_INSTANCE_OFFSET       = 0x0068; // ScriptInstance*                   Object::script_instance
    vars.NODE_CHILDREN_OFFSET                = 0x01C8; // HashMap<StringName, Node*>        Node::Data::children
    vars.NODE_NAME_OFFSET                    = 0x0228; // StringName                        Node::Data::name

    // ScriptInstance / GDScript
    vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET    = 0x0018; // Ref<GDScript>                     GDScriptInstance::script
    vars.SCRIPTINSTANCE_MEMBERS_OFFSET       = 0x0028; // Vector<Variant>                   GDScriptInstance::members
    vars.GDSCRIPT_MEMBER_MAP_OFFSET          = 0x0258; // HashMap<StringName, MemberInfo>   GDScript::member_indices

    // CanvasLayer
    vars.CANVASLAYER_VISIBLE_OFFSET          = 0x0454; // bool                              CanvasLayer::visible

    // CharacterBody3D
    vars.CHARACTERBODY3D_VELOCITY_OFFSET     = 0x0648; // Vector3                           CharacterBody3D::velocity
}

init
{
    vars.AccIgt = 0;
    vars.OneLevelCompleted = false;
    vars.killsAtCompletion = 0;
    
    current.igt = old.igt = -1;
    current.checkpointNum = old.checkpointNum = 0;
    current.scene = old.scene = "MainScreen";
    current.levelFinished = old.levelFinished = false;
    current.levelWasRestarted = old.levelWasRestarted = false;
    current.killCount = old.killCount = 0;

    // todo: properly read stringnames
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

    // static SceneTree *SceneTree::singleton
    var scn = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);
    var sceneTreeTrg = new SigScanTarget(3, "4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74 7E") { OnFound = (p, s, ptr) => ptr + 0x4 + game.ReadValue<int>(ptr) };
    var sceneTreePtr = scn.Scan(sceneTreeTrg);

    // Iterate through the scene root nodes to find the nodes we need
    var sceneTree       = game.ReadValue<IntPtr>((IntPtr)sceneTreePtr);
    var rootWindow      = game.ReadValue<IntPtr>((IntPtr)(sceneTree + vars.SCENETREE_ROOT_WINDOW_OFFSET));
    var childCount      = game.ReadValue<int>((IntPtr)(rootWindow + vars.NODE_CHILDREN_OFFSET));
    var childArrayPtr   = game.ReadValue<IntPtr>((IntPtr)(rootWindow + vars.NODE_CHILDREN_OFFSET + 0x8));

    var gameManager     = IntPtr.Zero;
    var statsService    = IntPtr.Zero;
    var endLevelScreen  = IntPtr.Zero;

    for (int i = 0; i < childCount; i++)
    {
        var child = game.ReadValue<IntPtr>(childArrayPtr + (0x8 * i));
        var childName = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)(child + vars.NODE_NAME_OFFSET)));
        if(childName == "GameManager")         
            gameManager = child;
        else if(childName == "StatsService")   
            statsService = child;
        else if(childName == "EndLevelScreen") 
            endLevelScreen = child;
    }

    if(sceneTree == IntPtr.Zero || gameManager == IntPtr.Zero || endLevelScreen == IntPtr.Zero || statsService == IntPtr.Zero)
        throw new Exception("SceneTree/GameManager/EndLevelScreen/StatsService not found - trying again!");

    gameManager    = game.ReadValue<IntPtr>((IntPtr)(gameManager + vars.OBJECT_SCRIPT_INSTANCE_OFFSET));
    statsService   = game.ReadValue<IntPtr>((IntPtr)(statsService + vars.OBJECT_SCRIPT_INSTANCE_OFFSET));

    var gameManagerScript  = game.ReadValue<IntPtr>((IntPtr)(gameManager + vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET));
    var statsServiceScript = game.ReadValue<IntPtr>((IntPtr)(statsService + vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET));

    var memberOffsets = new Dictionary<string, Dictionary<string, int>>();
    Func<IntPtr, Dictionary<string, int>> GetOffsets = (script) =>
    {
        var result = new Dictionary<string, int>();
        var memberPtr     = game.ReadValue<IntPtr>((IntPtr)(script + vars.GDSCRIPT_MEMBER_MAP_OFFSET));
        var lastMemberPtr = game.ReadValue<IntPtr>((IntPtr)(script + vars.GDSCRIPT_MEMBER_MAP_OFFSET + 0x8));
        int memberSize    = 0x18;

        while (memberPtr != IntPtr.Zero)
        {
            var namePtr = game.ReadValue<IntPtr>((IntPtr)(memberPtr + 0x10));
            string memberName = vars.ReadStringName(namePtr);

            if (string.IsNullOrEmpty(memberName))
            {
                var fallbackNamePtr = game.ReadValue<IntPtr>((IntPtr)(namePtr + 0x8));
                memberName = game.ReadString(fallbackNamePtr, 255);
            }

            var index = game.ReadValue<int>((IntPtr)(memberPtr + 0x18));
            result[memberName] = index * memberSize + 0x8;

            if (memberPtr == lastMemberPtr)
                break;

            memberPtr = game.ReadValue<IntPtr>((IntPtr)memberPtr);
        }

        return result;
    };

    memberOffsets["game_manager"]  = GetOffsets(gameManagerScript);
    memberOffsets["stats_service"] = GetOffsets(statsServiceScript);

    var gmMembers = memberOffsets["game_manager"];
    var ssMembers = memberOffsets["stats_service"];

    var gmMembersArray = game.ReadValue<IntPtr>((IntPtr)(gameManager  + vars.SCRIPTINSTANCE_MEMBERS_OFFSET));
    var ssMembersArray = game.ReadValue<IntPtr>((IntPtr)(statsService + vars.SCRIPTINSTANCE_MEMBERS_OFFSET));

    vars.Watchers = new MemoryWatcherList
    {
        new MemoryWatcher<double> (new DeepPointer(gmMembersArray + gmMembers["_total_game_seconds_obfuscated"])) { Name = "total_game_seconds" },
        new MemoryWatcher<int>    (new DeepPointer(gmMembersArray + gmMembers["current_checkpoint"]))             { Name = "current_checkpoint" },
        new MemoryWatcher<IntPtr> (new DeepPointer(gmMembersArray + gmMembers["player"] + 0x8))                   { Name = "player" },
        new MemoryWatcher<IntPtr> (new DeepPointer(ssMembersArray + ssMembers["_enemies_killed"]))                { Name = "enemies_killed_dict" },
        new MemoryWatcher<IntPtr> (new DeepPointer(ssMembersArray + ssMembers["_locked_in_keys"]))                { Name = "locked_keys_dict" },

        new MemoryWatcher<bool>   (new DeepPointer(endLevelScreen + vars.CANVASLAYER_VISIBLE_OFFSET))             { Name = "level_end_screen_visible" },
        new MemoryWatcher<IntPtr> (new DeepPointer(sceneTree      + vars.SCENETREE_CURRENT_SCENE_OFFSET))         { Name = "current_scene"},
    };

    vars.Watchers.UpdateAll(game);
}

update
{
    vars.Watchers.UpdateAll(game);

    current.checkpointNum      = vars.Watchers["current_checkpoint"].Current;
    current.levelFinished      = vars.Watchers["level_end_screen_visible"].Current;
    current.levelWasRestarted  = vars.Watchers["locked_keys_dict"].Current != vars.Watchers["locked_keys_dict"].Old;

    var currentSceneNode = vars.Watchers["current_scene"].Current;
    var newScene = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)(currentSceneNode + vars.NODE_NAME_OFFSET)));
    current.scene = String.IsNullOrEmpty(newScene) ? old.scene : newScene;

    current.inMainMenu = current.scene == "MainScreen";

    current.igt = current.inMainMenu ? 0f : ((vars.Watchers["total_game_seconds"].Current - 7.2) / 13.3);
    current.igt = Math.Floor(current.igt * 1000) / 1000;

    // Once a level is completed, auto-reset is disabled and IGT is accumulated
    if(current.levelFinished && !vars.OneLevelCompleted)
    {
        vars.OneLevelCompleted = true;
    }

    if(vars.OneLevelCompleted && current.igt < old.igt && old.scene != "MainScreen")
    {
        var offset = old.igt;
        if(settings["aprilComp"])
        {
            offset += vars.killsAtCompletion * (-0.9f);
            vars.killsAtCompletion = 0;
        }

        vars.AccIgt += offset;
        vars.Log("Accumulated "+offset.ToString("0.00")+" seconds of igt on "+old.scene);
    }

    if(settings["speedometer"])
    {
        var player = (IntPtr)vars.Watchers["player"].Current;
        var xVel = game.ReadValue<float>((IntPtr)(player + vars.CHARACTERBODY3D_VELOCITY_OFFSET));
        var zVel = game.ReadValue<float>((IntPtr)(player + vars.CHARACTERBODY3D_VELOCITY_OFFSET + 0x8));
        current.speed = Math.Sqrt((xVel * xVel) + (zVel * zVel));
        var speedString = current.speed.ToString("0.0") + " m/s";
        vars.SetTextComponent("Speed", speedString);
    }

    if(settings["aprilComp"])
    {
        // I think this is a HashMap<Variant, Variant, VariantHasher, StringLikeVariantComparator> variant_map
        var killedEnemiesDict = (IntPtr)vars.Watchers["enemies_killed_dict"].Current;
        var totalCount = game.ReadValue<int>(killedEnemiesDict + 0x3C);
        var killCount = 0;
        var entry = game.ReadValue<IntPtr>(killedEnemiesDict + 0x28);
        for (int i = 0; i < totalCount; i++)
        {
            if(game.ReadValue<bool>(entry+0x30))
                killCount++;
            entry = game.ReadValue<IntPtr>(entry);
        }

        current.killCount = killCount;

        if(settings["enemyCounter"])
        {
            vars.SetTextComponent("Enemies killed", killCount + "/" + totalCount);
        }

        if(current.levelFinished && !old.levelFinished)
        {
            vars.killsAtCompletion = killCount;
        }
    }
}


isLoading
{
    return true;
}

gameTime
{
    if(settings["aprilComp"])
    {
        return TimeSpan.FromSeconds(vars.AccIgt + current.igt + (current.killCount * -0.9f));
    }
    else
    {
        return TimeSpan.FromSeconds(vars.AccIgt + current.igt);
    }
}

split
{
    return (settings["checkpointSplit"] && current.checkpointNum > old.checkpointNum)
        || (settings["endlevelSplit"] && current.levelFinished && !old.levelFinished);
}

start
{
    return (current.igt > old.igt && old.igt <= 0.1)
        && !current.inMainMenu;
}

onStart
{
    vars.AccIgt = 0f;
    vars.OneLevelCompleted = false;
    vars.killsAtCompletion = 0;
}

reset
{
    return (
        !current.inMainMenu && current.levelWasRestarted && !old.levelWasRestarted && (!vars.OneLevelCompleted || settings["ilMode"])
    );
}

exit
{
    timer.IsGameTimePaused = true;
}