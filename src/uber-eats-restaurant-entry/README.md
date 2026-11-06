# Uber Eats restaurant opening

Opening a restaurant from Search can leave the search document involved in focus recovery after the restaurant menu is on screen. This script opens the same restaurant after switching to the native Account screen. The restaurant link and its parameters are preserved.

**Back from the restaurant returns to Account.**

To use it, install `uber-eats-restaurant-entry.zip`, leave the script enabled, and open a restaurant search result with the usual double tap. If Uber Eats shows an intermediate screen, choose **View restaurant** as usual. Other double taps keep their normal behavior. The script's setting can turn the workaround off.

The ZIP includes the Lua source and Polish translations of the script's English interface. Account is recognized using Uber Eats' own translated resources; readiness is checked by the native Account screen's view ID. On the normal path only the current labels are read. Other translations are resolved on demand, using installed language splits when available, and cached for later openings. There is no resource preloading when the app opens and no per-flick hook.

The `java` permission is used to read the focused link's destination and Uber Eats' resources through SandFly. The implementation uses SandFly's `TalkBackService` class and Uber Eats' native view/resource names. If it cannot complete the switch, it attempts to open the captured restaurant link normally.

From this directory, `lua tests/run.lua` runs 19 regression scenarios with Lua 5.4 and stand-in Android/SandFly objects. They cover eight interface-language fixtures, deferred resource reads, the cached normal path, language-split filtering, unchanged destinations and failure handling.

To rebuild the package, run this from this directory:

```sh
python -m zipfile -c ../../uber-eats-restaurant-entry.zip main.lua locales
```

The generated package can then be signed through SandFly's usual signing process.
