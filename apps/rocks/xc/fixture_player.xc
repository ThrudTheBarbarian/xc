// fixture_player.xc — a controller as an app would write it, for test_rkconnect: two outlets and
// two actions, declared with the `outlet` and `:action` decorations, so the compiler makes it
// designable and writes them into the interface file Rocks reads.
#import "UXDesignable.xc"
#import "UXRsc.xc"

i32 gPlays;
i32 gStops;

class PlayerController : Object
    {
    outlet UXButton* playButton;
    outlet UXTextField* titleField;

    void onPlay(UXControl* sender) : action
        {
        gPlays = gPlays + (i32)1;
        }
    void onStop(UXControl* sender) : action
        {
        gStops = gStops + (i32)1;
        }
    }
