# Birdsong Alarm

An iPhone alarm that wakes you with a random Midwest bird, then shows who is singing:
picture, name, three facts. Built for **iOS 26 or newer** and a **Windows PC with no Mac**.

## What rings, and when

| Layer | What it does | Works when |
|---|---|---|
| **System alarm** (Apple AlarmKit) | Plays the day's layered chorus on a loop until you stop it. Stop and "Meet the bird" buttons on the lock screen | Phone locked, on Silent, in a Focus, app closed, after a restart |
| **Waking screen** | Bird image, bold name, fact card, Dismiss Alarm button. The chorus carries on inside the app until you dismiss | When you open the app from the alarm |

**The chorus** is baked into the alarm sound itself, because a closed app cannot play
audio. Each bird has a 28-second clip: the day's bird fades in alone, a second bird joins
at 8 seconds and a third at 16. iOS loops the clip for as long as the alarm rings. If the
app happens to be open on screen at the alarm time, it plays the longer version: a
60-second build with companions at 20 and 40 seconds.

**It runs until you end it.** Neither the system alarm nor the in-app chorus has a time
limit. Stop on the lock screen ends both. Dismiss Alarm in the app ends both.

**Nothing stays awake.** Between alarms the app does not run, play silent audio, or hold
the screen on. The system alarm is scheduled with iOS and the app goes back to sleep.

**It cannot run out.** The app keeps seven system alarms in place, one per weekday, each
repeating weekly and each carrying the bird for that weekday's next morning. Every time the
app gets a chance to run (opening it, tapping Stop or "Meet the bird", dismissing), it
checks those seven alarms and corrects only what differs. If the app never runs again, the
alarms keep ringing; the only thing that degrades is that a bird repeats after a week.
Because the alarms are set as a time of day, they follow the phone's local time when you
travel.

**The shuffle** works like a deck of cards: every bird sings once before any bird repeats,
then the deck is reshuffled into a new order. The reshuffle keeps a minimum gap, so with
20 birds the same bird is always at least 10 mornings apart. Each morning's bird is calculated from the
calendar date, with nothing stored on the phone, so the weekly re-sign, an app update, or
even deleting and reinstalling the app cannot reset it or cause an early repeat.

## Simulated: 1,000 days of use

`python tools/simulate.py` runs a Python model of the alarm engine against a simulated
iPhone and owner: the app being suspended or killed overnight, reboots, refused scheduling
calls, crashes mid-update, time-zone trips, alarm-time changes, late re-signs, and owners
who only ever tap Stop. It compares the first design ("old") with the current one ("new").

| Per 1,000 days | Old: engaged owner | Old: owner who only taps Stop | New: any owner |
|---|---|---|---|
| Missed alarms | 30 | 327 | 0 |
| Rings at the wrong local hour | 25 | 35 | 0 |
| Stale bird card shown | 220 | 56 | 0 |

A 10-year, 20-run soak of the new design also recorded zero missed alarms. This is a model
of the logic, not a test of the real app: it assumes iOS behaves as Apple documents, in
particular that a time-of-day alarm follows the phone's local time. Two pessimistic
switches show what is left: `--expiry-silences` (if an expired signature stops alarms, every
late re-sign day is a missed alarm) and `--stop-never-wakes-app` (alarms still ring, but a
bird can repeat after a week).

## Status: what has and has not been tested

- **Not compiled.** The Swift code was written without access to Xcode. The first cloud
  build is the first compile. If it fails, the workflow uploads a `build-log` file; send
  the lines containing `error:` and they can be fixed.
- **Not confirmed:** that AlarmKit accepts an app signed with a free Apple ID. It needs
  only an Info.plist text entry, not a paid capability, so it should, but nobody has run it.
- **Tested:** the asset scripts (against mock data and a real ffmpeg), the web demo.
- **Not tested against the live services:** downloads from xeno-canto and iNaturalist.

## Deploy from Windows

### Part 1. Build the app on a free cloud Mac (about 15 minutes, once)

1. Create a free account at github.com.
2. Install **Git for Windows** (git-scm.com) and open this folder in VS Code.
3. In VS Code, open the Source Control panel and choose **Publish to GitHub**. Pick
   **private repository**. Sign in when asked.
4. On github.com open the repository, go to the **Actions** tab, and watch **Build iPhone
   app** run. It takes roughly 10 minutes. It downloads the bird recordings and photos,
   cuts the alarm clips, and compiles the app.
5. When it shows a green tick, open the run and download **BirdsongAlarm-ipa** at the
   bottom of the page. Unzip it to get `BirdsongAlarm.ipa`.

Optional, for better recordings: make a free xeno-canto.org account, copy the API key
from your account page, and add it under repository Settings > Secrets and variables >
Actions > New repository secret, named `XC_API_KEY`. Then press **Run workflow** on the
Actions tab. Without the key, recordings come from iNaturalist, which has no quality ratings.

### Part 2. Install it on the iPhone (about 15 minutes, once)

1. Install **iTunes** and **iCloud** for Windows from apple.com (the installers from
   Apple's site, not the Microsoft Store versions).
2. Install **Sideloadly** (sideloadly.io). AltStore (altstore.io) is an open-source
   alternative that works the same way.
3. Plug the iPhone into the PC with a cable. Tap **Trust** on the phone.
4. Open Sideloadly, drag `BirdsongAlarm.ipa` into it, enter your Apple ID, press **Start**.
   The tool signs the app with your Apple ID. Some people create a second Apple ID for this.
5. On the iPhone: Settings > General > VPN & Device Management > tap your Apple ID > **Trust**.
6. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on. The phone restarts.
7. Open **Birdsong**, set a time, switch **Alarm** on, and tap **Allow** when iOS asks
   about alarms.

### Part 3. Check it (5 minutes)

1. Tap **Preview waking screen**. You should hear the chorus build and see a bird card.
2. Set the alarm two minutes ahead, lock the phone, flip it to Silent. It should ring,
   and keep ringing past the 28-second mark until you tap Stop.
3. Repeat with the app swiped away in the app switcher. It should still ring.

### Every week

Apps signed with a free Apple ID stop opening after 7 days. Sideloadly can refresh the
app automatically while the phone and PC are on the same Wi-Fi, or you can press Start
again with the same file. The $99 per year Apple Developer Program removes this limit.
Whether alarms still ring after the signature lapses is not known, so refresh before it
does. The app helps: the home screen shows when the signature runs out, warns two days
ahead, and the last alarm before the deadline says "Re-sign Birdsong today" on screen.

## Hurdles you may hit

| Hurdle | Fix |
|---|---|
| Cloud build fails at "Compile" | Download the `build-log` file from the run and send the `error:` lines |
| Cloud build fails at "Download bird recordings" | The services refused the downloads. Add the `XC_API_KEY` secret and re-run |
| Birdsong plays once for 28 seconds, then goes quiet | Early iOS 26 versions did not loop custom alarm sounds. Update the iPhone to the latest iOS 26 |
| Alarm rings with the standard iPhone tone, not a bird | Custom alarm sounds were broken in iOS 26.0. Update the iPhone to the latest iOS 26 |
| Sideloadly cannot see the phone | Use Apple's own iTunes installer, unlock the phone, and tap Trust |
| "Unable to verify app" on first launch | Trust your Apple ID under VPN & Device Management; needs internet once |
| Alarm is too quiet or too loud | Settings > Sounds & Haptics, ringer and alerts slider |

## The deck

20 folders in `assets/birds/`, each with `metadata.json` (name, scientific name, 3 facts).
The cloud build adds `audio` and `image` files. To use your own, drop `audio.mp3` and
`image.png` into a folder before publishing; the build keeps files that are already there.

## Other ways to run it

- **Web demo** (`index.html`): run `python tools/serve.py` and open the printed address.
  Useful for trying the look and the chorus. It cannot ring on a locked phone and has to
  keep the screen on, so it is a demo only.
- **On a Mac:** `brew install xcodegen ffmpeg`, then `python3 tools/fetch_assets.py`,
  `python3 tools/make_clips.py`, `xcodegen generate`, and open the project in Xcode 26.

## Licences

Recordings and photos are Creative Commons, mostly non-commercial, credited in
`assets/CREDITS.md` (included with each build). Keep the repository private unless you
are happy to publish those files with their credits.
