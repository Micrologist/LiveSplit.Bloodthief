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

    settings.Add("endlevelSplit",    true,  "Split when finishing a level");
    settings.Add("checkpointSplit",  false, "Split when reaching a checkpoint");
    settings.Add("ilMode",           false, "Always reset when restarting level (IL Mode)");
    settings.Add("aprilCompetition", true,  "Subtract 0.9 seconds for every kill (April Competition)"); 
    settings.Add("enemyCounter",     false, "Show enemy kill counter", "aprilCompetition");
    settings.Add("speedometer",      false, "Show speed");

    // Godot 4.4 Offsets
    // SceneTree
    vars.SCENETREE_ROOT_WINDOW_OFFSET        = 0x3A8; // Window*                           SceneTree::root
    vars.SCENETREE_CURRENT_SCENE_OFFSET      = 0x498; // Node*                             SceneTree::current_scene

    // Node / Object
    vars.OBJECT_SCRIPT_INSTANCE_OFFSET       = 0x068; // ScriptInstance*                   Object::script_instance
    vars.NODE_CHILDREN_OFFSET                = 0x1C8; // HashMap<StringName, Node*>        Node::Data::children
    vars.NODE_NAME_OFFSET                    = 0x228; // StringName                        Node::Data::name

    // GDScriptInstance
    vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET    = 0x018; // Ref<GDScript>                     GDScriptInstance::script
    vars.SCRIPTINSTANCE_MEMBERS_OFFSET       = 0x028; // Vector<Variant>                   GDScriptInstance::members

    // GDScript
    vars.GDSCRIPT_MEMBER_MAP_OFFSET          = 0x258; // HashMap<StringName, MemberInfo>   GDScript::member_indices

    // CanvasLayer
    vars.CANVASLAYER_VISIBLE_OFFSET          = 0x454; // bool                              CanvasLayer::visible

    // CharacterBody3D
    vars.CHARACTERBODY3D_VELOCITY_OFFSET     = 0x648; // Vector3                           CharacterBody3D::velocity


    // April Speedrun Competition
    vars.MS_PER_KILL = 900;
}

init
{
    vars.AccIgt = 0;
    vars.OneLevelCompleted = false;
    vars.killsAtCompletion = 0;
    
    // StringNames contain either a Godot String object (Utf32) or a C-string pointer
    vars.ReadStringName = (Func<IntPtr, string>) ((ptr) => {
        var stringPtr = game.ReadValue<IntPtr>(ptr + 0x10);
        var output = vars.ReadUtf32String(stringPtr);

        if(String.IsNullOrEmpty(output))
        {
            // Read C-String instead
            stringPtr = game.ReadValue<IntPtr>(ptr + 0x8);
            output = game.ReadString(stringPtr, 255);
        }
        return output;
    });

    vars.ReadUtf32String = (Func<IntPtr, string>)((ptr) =>
    {
        var sb = new StringBuilder();
        int utf32char;

        while ((utf32char = game.ReadValue<int>(ptr)) != 0)
        {
            sb.Append(char.ConvertFromUtf32(utf32char));
            ptr += 4;
        }

        return sb.ToString();
    });

    // static SceneTree *SceneTree::singleton
    var scn = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);
    var sceneTreeTrg = new SigScanTarget(3, "4C 8B 35 ?? ?? ?? ?? 4D 85 F6 74 7E") { OnFound = (p, s, ptr) => ptr + 0x4 + game.ReadValue<int>(ptr) };
    var sceneTreePtr = scn.Scan(sceneTreeTrg);

    // Iterate through the scene root nodes to find the nodes we need
    var sceneTree      = game.ReadValue<IntPtr>((IntPtr)(sceneTreePtr));
    var rootWindow     = game.ReadValue<IntPtr>((IntPtr)(sceneTree  + vars.SCENETREE_ROOT_WINDOW_OFFSET));
    var childCount     = game.ReadValue<int>   ((IntPtr)(rootWindow + vars.NODE_CHILDREN_OFFSET));
    var childArrayPtr  = game.ReadValue<IntPtr>((IntPtr)(rootWindow + vars.NODE_CHILDREN_OFFSET + 0x8));

    var gameManager     = IntPtr.Zero;
    var statsService    = IntPtr.Zero;
    var endLevelScreen  = IntPtr.Zero;

    for (int i = 0; i < childCount; i++)
    {
        var child = game.ReadValue<IntPtr>(childArrayPtr + (0x8 * i));
        var childName = vars.ReadStringName(game.ReadValue<IntPtr>((IntPtr)(child + vars.NODE_NAME_OFFSET)));

        switch ((String)childName)
        {
            case "GameManager":
                gameManager = child;
                break;
            case "StatsService":
                statsService = child;
                break;
            case "EndLevelScreen":
                endLevelScreen = child;
                break;
        }
    }

    if(gameManager == IntPtr.Zero || endLevelScreen == IntPtr.Zero || statsService == IntPtr.Zero)
        throw new Exception("SceneTree/GameManager/EndLevelScreen/StatsService not found - trying again!");

    Func<IntPtr, Dictionary<string, int>> GetMemberOffsets = (script) =>
    {
        var result = new Dictionary<string, int>();
        var memberPtr     = game.ReadValue<IntPtr>((IntPtr)(script + vars.GDSCRIPT_MEMBER_MAP_OFFSET));
        var lastMemberPtr = game.ReadValue<IntPtr>((IntPtr)(script + vars.GDSCRIPT_MEMBER_MAP_OFFSET + 0x8));
        int memberSize = 0x18;

        while (memberPtr != IntPtr.Zero)
        {
            var namePtr = game.ReadValue<IntPtr>(memberPtr + 0x10);
            string memberName = vars.ReadStringName(namePtr);

            var index = game.ReadValue<int>(memberPtr + 0x18);
            result[memberName] = index * memberSize + 0x8;

            if (memberPtr == lastMemberPtr)
                break;

            memberPtr = game.ReadValue<IntPtr>(memberPtr);
        }

        return result;
    };

    // Get the ScriptInstance from the Node
    gameManager  = game.ReadValue<IntPtr>((IntPtr)(gameManager  + vars.OBJECT_SCRIPT_INSTANCE_OFFSET));
    statsService = game.ReadValue<IntPtr>((IntPtr)(statsService + vars.OBJECT_SCRIPT_INSTANCE_OFFSET));

    // Dump the offsets from the GDScript
    var gmOffsets = GetMemberOffsets(game.ReadValue<IntPtr>((IntPtr)(gameManager  + vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET)));
    var ssOffsets = GetMemberOffsets(game.ReadValue<IntPtr>((IntPtr)(statsService + vars.SCRIPTINSTANCE_SCRIPT_REF_OFFSET)));

    var gmMembers = game.ReadValue<IntPtr>((IntPtr)(gameManager  + vars.SCRIPTINSTANCE_MEMBERS_OFFSET));
    var ssMembers = game.ReadValue<IntPtr>((IntPtr)(statsService + vars.SCRIPTINSTANCE_MEMBERS_OFFSET));

    vars.UpdateState = (Action)(()=> 
    {
        var sceneNode = game.ReadValue<IntPtr>((IntPtr)(sceneTree + vars.SCENETREE_CURRENT_SCENE_OFFSET));
        var sceneName = game.ReadValue<IntPtr>((IntPtr)(sceneNode + vars.NODE_NAME_OFFSET));
        var newScene = vars.ReadStringName(sceneName);
        current.scene = !String.IsNullOrEmpty(newScene) ? newScene : current.scene;
        current.inMainMenu = current.scene == "MainScreen";

        current.levelFinished = game.ReadValue<bool>((IntPtr)(endLevelScreen + vars.CANVASLAYER_VISIBLE_OFFSET));

        var obfuscatedIgt = game.ReadValue<double>(gmMembers + gmOffsets["_total_game_seconds_obfuscated"]);
        var doubleIgt = (obfuscatedIgt - 7.2) / 13.3;
        current.igt = !current.inMainMenu ? Math.Round((double)doubleIgt * 1000) : 0;
        
        current.checkpointNum = game.ReadValue<int>   (gmMembers + gmOffsets["current_checkpoint"]);
        // Variants of type OBJECT have their data pointer 0x8 bytes further
        current.playerPtr     = game.ReadValue<IntPtr>(gmMembers + gmOffsets["player"] + 0x8);

        current.enemiesKilledDict = game.ReadValue<IntPtr>(ssMembers + ssOffsets["_enemies_killed"]);
        current.lockedKeysDict =    game.ReadValue<IntPtr>(ssMembers + ssOffsets["_locked_in_keys"]);
        
    });

    vars.UpdateKillCount = (Action)(() => 
    {
        IntPtr enemyDict = current.enemiesKilledDict;
        current.enemyCount = game.ReadValue<int>(enemyDict + 0x3C);
        var killCount = 0;

        var entry = game.ReadValue<IntPtr>(enemyDict + 0x28);
        for (int i = 0; i < current.enemyCount; i++)
        {
            if(game.ReadValue<bool>(entry+0x30))
                killCount++;
            entry = game.ReadValue<IntPtr>(entry);
        }

        current.killCount = killCount;
    });

    vars.UpdateState();
}

update
{
    vars.UpdateState();

    // This dictionary gets reinitialized when a map is (re-)loaded
    current.levelWasRestarted = current.lockedKeysDict != old.lockedKeysDict;

    // Once a level is completed, auto-reset is disabled and IGT is accumulated
    if(current.levelFinished && !vars.OneLevelCompleted)
    {
        vars.OneLevelCompleted = true;
    }

    if(vars.OneLevelCompleted && current.igt < old.igt && old.scene != "MainScreen")
    {
        var acc = old.igt;

        if(settings["aprilCompetition"])
        {
            acc -= vars.killsAtCompletion * vars.MS_PER_KILL;
            vars.killsAtCompletion = 0;
        }

        vars.AccIgt += acc;
        vars.Log("Accumulated "+acc.ToString("0.00")+" seconds of igt on "+old.scene);
    }

    if(settings["speedometer"])
    {
        var player = current.playerPtr;
        var xVel = game.ReadValue<float>((IntPtr)(player + vars.CHARACTERBODY3D_VELOCITY_OFFSET));
        var zVel = game.ReadValue<float>((IntPtr)(player + vars.CHARACTERBODY3D_VELOCITY_OFFSET + 0x8));
        current.speed = Math.Sqrt((xVel * xVel) + (zVel * zVel));
        
        var speedString = current.speed.ToString("0.0") + " m/s";
        vars.SetTextComponent("Speed", speedString);
    }

    if(settings["aprilCompetition"])
    {
        vars.UpdateKillCount();

        if(current.levelFinished && !old.levelFinished)
        {
            vars.killsAtCompletion = current.killCount;
        }

        if(settings["enemyCounter"])
        {
            vars.SetTextComponent("Enemies killed", current.killCount + "/" + current.enemyCount);
        }
    }
}

isLoading
{
    return true;
}

gameTime
{
    var gameTime = vars.AccIgt + current.igt;

    if(settings["aprilCompetition"])
    {
        gameTime -= current.killCount * vars.MS_PER_KILL;
    }

    return TimeSpan.FromSeconds(gameTime / 1000);
}

split
{
    return (settings["checkpointSplit"] && current.checkpointNum > old.checkpointNum)
        || (settings["endlevelSplit"] && current.levelFinished && !old.levelFinished);
}

start
{
    return (current.igt > old.igt && old.igt <= 50)
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