#!/usr/bin/liquidsoap

################################################################################
#                           LIQUIDSOAP SCHEDULER SCRIPT                       #
################################################################################


# Parse command line arguments
# argv(1): user_id (required)
# argv(2): sanctum bearer token (optional; recommended for multi-user secure mode)
# argv(3): control port for Harbor HTTP endpoints (optional; default 7000)
# argv(4): prayer mute enable flag ("1" to enable, default disabled for safety)
user_id = ref(argv(default="fail", 1))
api_token = ref(argv(default="", 2))
control_port = ref(int_of_string(default=7000, argv(default="7000", 3)))
prayer_mute_enabled = ref(argv(default="0", 4) == "1")

if user_id() == "fail" then
  shutdown()
end

# Configuration
#settings.init.daemon.set(bool_of_string(argv(default="true", 2)))
#settings.init.daemon.pidfile.path.set("/home/oooomedia/liq_scripts/pids/#{user_id()}.pid")
settings.log.file := true
settings.log.file.path := "/home/oooomedia/liq_scripts/logs/#{user_id()}.log"

# Global Variables
music_log = playlog(duration=3600.)
ads_log = playlog(duration=3600.)
current_loop = ref("")
base_uri = ref("https://stagingtm.displayer25.com/api/"^user_id())
played_ad_count = ref(0)
last_skip_block = ref(-1)
last_skip_loop = ref("")
prayer_times = ref([])
prayer_enabled = ref(true)
current_source_type = ref("music")
next_track_duration = ref(0.0)

# EQ Configuration Variables
eq_preset = ref("flat")
eq_config_file = "/home/oooomedia/liq_scripts/configs/#{user_id()}_eq.conf"
eq_available = ref(true)

# Icecast Variables
icecast_host = ref("")
icecast_port = ref(8000)
icecast_mount = ref("")
icecast_user = ref("")
icecast_pass = ref("")
icecast_bitrate = ref("320k")
ice_shutdown = ref([])

################################################################################
#                              CORE FUNCTIONS                                  #
################################################################################

# EQ Preset Definitions with 10-band graphic EQ parameters
# Frequencies: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz
def get_eq_preset_params(preset_name)
  if preset_name == "flat" then
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  elsif preset_name == "vocal_boost" then
    [0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 2.0, 1.0, 0.0, 0.0]
  elsif preset_name == "bass_heavy" then
    [6.0, 4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 1.0, 2.0, 1.0]
  elsif preset_name == "bright" then
    [0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 4.0]
  elsif preset_name == "warm" then
    [3.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -1.0, -2.0, -2.0]
  elsif preset_name == "radio_classic" then
    [1.0, 1.0, 0.0, 1.0, 2.0, 3.0, 2.0, 1.0, 0.0, -1.0]
  elsif preset_name == "pop" then
    [4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 1.0, 2.0, 4.0, 3.0]
  elsif preset_name == "rock" then
    [3.0, 1.0, 0.0, 1.0, 2.0, 1.0, 0.0, 1.0, 3.0, 2.0]
  elsif preset_name == "classical" then
    [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 2.0]
  else
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  end
end

# Load EQ preset from config file
def load_eq_preset()
  try
    if file.exists(eq_config_file) then
      content = file.contents(eq_config_file)
      preset = string.trim(content)
      if list.mem(preset, ["flat", "vocal_boost", "bass_heavy", "bright", "warm", "radio_classic", "pop", "rock", "classical"]) then
        eq_preset := preset
        log("INFO: EQ preset loaded: #{preset}")
      else
        log("WARNING: Invalid EQ preset in config file, using radio_classic")
        eq_preset := "radio_classic"
      end
    else
      log("INFO: No EQ config file found, using default preset: radio_classic")
      eq_preset := "radio_classic"
    end
  catch err do
    log("ERROR: Failed to load EQ preset: #{err}, using radio_classic")
    eq_preset := "radio_classic"
  end
end

# Save EQ preset to config file
def save_eq_preset()
  try
    # Ensure config directory exists
    ignore(process.run("mkdir -p /home/oooomedia/liq_scripts/configs"))
    file.write(data=eq_preset(), eq_config_file)
    log("INFO: EQ preset saved: #{eq_preset()}")
  catch err do
    log("ERROR: Failed to save EQ preset: #{err}")
  end
end

# Apply EQ to audio stream using basic amplification
def apply_eq_to_stream(source)
  if not eq_available() then
    log("WARNING: EQ not available, bypassing")
    source
  else
    try
      preset_params = get_eq_preset_params(eq_preset())

      # Calculate overall gain adjustment based on preset
      # Focus on the most important frequency ranges for radio
      bass_gain = (list.nth(preset_params, 0) + list.nth(preset_params, 1) + list.nth(preset_params, 2)) / 3.0
      mid_gain = (list.nth(preset_params, 3) + list.nth(preset_params, 4) + list.nth(preset_params, 5) + list.nth(preset_params, 6)) / 4.0
      high_gain = (list.nth(preset_params, 7) + list.nth(preset_params, 8) + list.nth(preset_params, 9)) / 3.0

      # Apply overall tonal adjustment
      total_gain = (bass_gain * 0.3) + (mid_gain * 0.4) + (high_gain * 0.3)

      # Apply EQ using basic amplification based on preset
      if total_gain != 0.0 then
        # Apply gentle gain adjustment (max ±3dB)
        gain_factor = 1.0 + (total_gain * 0.03)
        if gain_factor > 0.1 and gain_factor < 3.0 then
          log("INFO: Basic EQ applied with preset: #{eq_preset()} (gain: #{total_gain}dB)")
          amplify(gain_factor, source)
        else
          log("INFO: EQ gain factor out of bounds, bypassing")
          source
        end
      else
        log("INFO: EQ preset has no gain adjustment: #{eq_preset()}")
        source
      end
    catch err do
      log("ERROR: EQ processing failed: #{err}, bypassing EQ")
      eq_available := false
      source
    end
  end
end

# Test EQ availability (amplify should always be available)
def test_eq_availability()
  try
    # Test basic amplify functionality
    test_source = sine(440.0, duration=0.1)
    ignore(amplify(1.0, test_source))
    eq_available := true
    log("INFO: Basic EQ (amplify) available and working")
  catch err do
    eq_available := false
    log("WARNING: Basic EQ not available: #{err}")
  end
end

def http_get_with_auth(uri)
  if api_token() != "" then
    try
      http.get(uri, headers=[("Authorization", "Bearer "^api_token())])
    catch err do
      log("WARNING: Authenticated GET failed for #{uri}: #{err}. Retrying without auth header.")
      http.get(uri)
    end
  else
    http.get(uri)
  end
end

def api_response_preview(body)
  len = string.length(body)
  if len == 0 then
    "[empty body]"
  elsif len <= 300 then
    body
  else
    # Older Liquidsoap versions on the server have a different string.sub signature.
    # To stay compatible and avoid crashing, just log a generic truncated marker.
    "[truncated body preview, len="^string_of(len)^"]"
  end
end

def fetch_prayer_times()
  try
    result = http_get_with_auth("https://stagingtm.displayer25.com/api/prayer")
    let json.parse (j: {status: int, data: [{starttime: string, endtime: string}]}) = result
    if j.status == 200 then prayer_times := j.data end
  catch err do log("ERROR: Prayer fetch failed: #{err}") end
end

def is_prayer_time()
  # current_time = time.local()
  # current_hour = current_time.hour
  # current_minute = current_time.min
  # current_second = current_time.sec

  # Get current time in Dubai timezone (UTC+4) in HH:MM:SS format
  time_info = time.utc()
  # Add 4 hours for Dubai timezone (UTC+4)
  dubai_hour = (time_info.hour + 4) mod 24
  current_hour = dubai_hour
  current_minute = time_info.min
  current_second = time_info.sec

  # Format current time as HH:MM:SS string for comparison
  hour_str = if current_hour < 10 then "0#{current_hour}" else "#{current_hour}" end
  minute_str = if current_minute < 10 then "0#{current_minute}" else "#{current_minute}" end
  second_str = if current_second < 10 then "0#{current_second}" else "#{current_second}" end
  current_time_str = "#{hour_str}:#{minute_str}:#{second_str}"

  # Check if current time falls within any prayer period
  list.exists(
    fun(prayer) ->
      current_time_str >= prayer.starttime and current_time_str <= prayer.endtime,
    prayer_times()
  )
end

def api_call(uri)
  result = http_get_with_auth(uri)
  log("DEBUG API Response from #{uri}: #{result}")
  if string.length(string.trim(result)) == 0 then
    log("ERROR: Empty API response from #{uri} (check URL, auth token, TLS/DNS).")
    failwith("API empty response: "^uri)
  end
  try
    let json.parse (j: {status: int, data: {icecast: {host: string, port: string, user: string, pass: string, mount: string, bitrate: string}, loop: string, asset_path: string}}) = result
    j
  catch err do
    log("ERROR: Non-JSON API response from #{uri}: #{err}")
    log("ERROR: Body preview: #{api_response_preview(result)}")
    failwith("API JSON parse failed: "^uri)
  end
end

def add_track(stream)
  j = api_call(base_uri()^"/#{stream}")
  current_loop := j.data.loop

  # Log ad file names specifically
  if stream == "ad" then
    log("INFO: Prefetching ad file: #{j.data.asset_path}")
  end

  # Get duration of the file
  duration = 0.0
  try
    # Try to get duration directly from the file path
    duration = request.duration(j.data.asset_path)
    if duration > 0.0 then
      log("INFO: Got duration from file: #{duration}s for #{j.data.asset_path}")
      # Store duration for music tracks only
      if stream == "music" or stream == "4minutesmusic" then
        next_track_duration := duration
      end
    else
      log("WARNING: Could not get duration for #{j.data.asset_path}")
    end
  catch err do
    log("ERROR: Failed to get duration: #{err}")
  end

  # CRITICAL: Force start at 0.0 and ignore blank skipping
  # For ads, disable autocue completely to avoid any processing delays
  # Add metadata to identify track type and include duration
  track_uri = if stream == "music" or stream == "4minutesmusic" then
    if duration > 0.0 then
      'annotate:liq_cue_in=0.0,liq_blankskip=0.0,liq_cue_file=false,track_type="music",duration=#{duration}:'^j.data.asset_path
    else
      'annotate:liq_cue_in=0.0,liq_blankskip=0.0,liq_cue_file=false,track_type="music":'^j.data.asset_path
    end
  else
    # Disable autocue for ads to prevent any initial processing delay
    if duration > 0.0 then
      'annotate:liq_cue_file=false,track_type="ad",duration=#{duration}:'^j.data.asset_path
    else
      'annotate:liq_cue_file=false,track_type="ad":'^j.data.asset_path
    end
  end
  request.create(track_uri)
end

################################################################################
#                           PLAYOUT INITIALIZATION                             #
################################################################################

def init_playout_chain()
# Initial API Config
  j_init = api_call(base_uri()^"/music")
  icecast_host := j_init.data.icecast.host
  icecast_port := int_of_string(default=8000, j_init.data.icecast.port)
  icecast_mount := j_init.data.icecast.mount
  # Clean bitrate: remove any "k" if sent from API so int_of_string works
  icecast_bitrate := string.replace(pattern="k", (fun(_) -> ""), j_init.data.icecast.bitrate)
  icecast_user := j_init.data.icecast.user
  icecast_pass := j_init.data.icecast.pass

  # Multi-user safety: never publish two encoders to the same Icecast mount.
  # If API returns the same mount for different `user_id`, the last connected source wins
  # and the other station goes silent.
  mount_from_api = icecast_mount()
  mount_suffix = "_"^user_id()
  if not string.contains(substring=mount_suffix, mount_from_api) then
    icecast_mount := mount_from_api^mount_suffix
    log("INFO: Icecast mount adjusted for multi-user isolation: #{mount_from_api} -> #{icecast_mount()}")
  else
    log("INFO: Icecast mount already user-scoped: #{mount_from_api}")
  end

  fetch_prayer_times()

  # Initialize EQ system
  test_eq_availability()
  load_eq_preset()

  # Music sources with automatic crossfading
  # DUAL-SOURCE APPROACH: Create separate sources with and without crossfade

  # Variable to track if we just came from ads
  just_finished_ads = ref(false)
  # Counter for post-ads tracks (reset after one track)
  post_ads_track_count = ref(0)

  # Music sources - NO crossfade (tracks play back-to-back with no overlap)
  music_raw = request.dynamic(id="music", prefetch=1, {add_track("music")})
  music_4m_raw = request.dynamic(id="4minutesmusic", prefetch=1, {add_track("4minutesmusic")})

  # Alias for compatibility with existing code (no crossfade applied)
  music_crossfaded = music_raw
  music_4m_crossfaded = music_4m_raw

  # Sources for post-ads (same as regular - no crossfade)
  music_raw_no_cf = request.dynamic(id="music_no_cf", prefetch=1, {add_track("music")})
  music_4m_raw_no_cf = request.dynamic(id="4minutesmusic_no_cf", prefetch=1, {add_track("4minutesmusic")})

  # Track handlers for music sources
  def on_music_track(_)
    current_source_type := "music"
    log("INFO: Music track started")
  end

  music_raw.on_track(on_music_track)
  music_4m_raw.on_track(on_music_track)

  # Track handlers for non-crossfaded sources
  def on_music_no_cf_track(_)
    current_source_type := "music"
    log("INFO: Post-ads music track started (no crossfade)")

    # Increment counter
    post_ads_track_count := post_ads_track_count() + 1
    log("INFO: Post-ads track ##{post_ads_track_count()}")

    # After the FIRST post-ads track starts, reset the flag
    # This allows the SECOND track to use crossfade
    if post_ads_track_count() >= 1 then
      log("INFO: First post-ads track playing, will enable crossfade for next track")
      just_finished_ads := false
    end
  end

  def on_music_4m_no_cf_track(_)
    current_source_type := "music"
    log("INFO: Post-ads 4m music track started (no crossfade)")

    # Increment counter
    post_ads_track_count := post_ads_track_count() + 1
    log("INFO: Post-ads 4m track ##{post_ads_track_count()}")

    # After the FIRST post-ads track starts, reset the flag
    # This allows the SECOND track to use crossfade
    if post_ads_track_count() >= 1 then
      log("INFO: First post-ads 4m track playing, will enable crossfade for next track")
      just_finished_ads := false
    end
  end

  music_raw_no_cf.on_track(on_music_no_cf_track)
  music_4m_raw_no_cf.on_track(on_music_4m_no_cf_track)

  # Use fallback with dynamic availability based on flag
  # When just_finished_ads is true, only non-crossfaded source is available
  # When just_finished_ads is false, only crossfaded source is available

  # Make sources available only when their condition is true
  music_no_cf_available = source.available(music_raw_no_cf, {just_finished_ads()})
  music_4m_no_cf_available = source.available(music_4m_raw_no_cf, {just_finished_ads()})

  music_crossfaded_available = source.available(music_crossfaded, {not just_finished_ads()})
  music_4m_crossfaded_available = source.available(music_4m_crossfaded, {not just_finished_ads()})

  # Fallback that tries non-crossfaded first (only available when flag is true)
  # Then falls back to crossfaded (only available when flag is false)
  # Add blank as final safety fallback to prevent stream failure
  music_inner = fallback(track_sensitive=true, [
    music_no_cf_available,
    music_crossfaded_available,
    blank()
  ])

  music_4m_inner = fallback(track_sensitive=true, [
    music_4m_no_cf_available,
    music_4m_crossfaded_available,
    blank()
  ])

  # Increase prefetch for ads to give processing chain more initialization time
  ads = request.dynamic(id="ads", prefetch=1, {add_track("ad")})

  # Apply moderate processing to ads for consistent loudness without distortion
  # First apply moderate compression to even out dynamics
  #ads = compress.exponential(mu=1.0, ads)
  # Then add gentle amplification / remove aplification
  #ads = amplify(2.0, ads)  # 2.3dB boost
  # Add limiter to prevent any clipping
  #ads = limit(threshold=-6.0, attack=0.001, release=0.05, ads)
  ads = amplify(2.0, ads)  # 2.3dB boost
  log("INFO: Moderate compression (mu=5), 2.3dB boost, and soft limiting at -2dB applied to ads")

  # Function to check if we're approaching ad time
  def seconds_until_ads()
    time_in_hour = (time.utc().min * 60 + time.utc().sec) mod 3600

    # Get all ad times based on current loop
    ad_times = if current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K" then
      [240, 255, 270, 285, 540, 555, 570, 585, 840, 855, 870, 885,
       1140, 1155, 1170, 1185, 1440, 1455, 1470, 1485, 1740, 1755, 1770, 1785,
       2040, 2055, 2070, 2085, 2340, 2355, 2370, 2385, 2640, 2655, 2670, 2685,
       2940, 2955, 2970, 2985, 3240, 3255, 3270, 3285, 3540, 3555, 3570, 3585]
    elsif current_loop() == "C" then
      [240, 260, 280, 540, 560, 580, 840, 860, 880, 1140, 1160, 1180,
       1440, 1460, 1480, 1740, 1760, 1780, 2040, 2060, 2080, 2340, 2360, 2380,
       2640, 2660, 2680, 2940, 2960, 2980, 3240, 3260, 3280, 3540, 3560, 3580]
    elsif current_loop() == "D" then
      [540, 560, 580, 1140, 1160, 1180, 1740, 1760, 1780,
       2340, 2360, 2380, 2940, 2960, 2980, 3540, 3560, 3580]
    elsif current_loop() == "E" then
      [840, 860, 880, 1740, 1760, 1780, 2640, 2660, 2680, 3540, 3560, 3580]
    else
      []
    end

    # Find the next ad time
    next_ad = list.fold(fun(acc, t) ->
      if t > time_in_hour and (acc < 0 or t < acc) then t else acc end,
      -1, ad_times)

    if next_ad > 0 then next_ad - time_in_hour else -1 end
  end

  # Skip Logic: Clears the background music while ads are playing
  def skip_music_on_ad_or_ad(_)
    # Mark that we're playing ads
    current_source_type := "ads"

    # Reset the post-ads track counter when ads start
    post_ads_track_count := 0

    # CRITICAL: Skip crossfaded sources AND skip non-crossfaded sources
    # Crossfaded: prevent buffering during ads
    # Non-crossfaded: clear them so they don't have old tracks when needed
    log("INFO: Flushing all music sources")
    
    #music_crossfaded.skip()
    #music_4m_crossfaded.skip()
    #music_raw_no_cf.skip()
    #music_4m_raw_no_cf.skip()

    # Skip crossfaded again after delays to prevent re-buffering during ads
    #thread.run(delay=1.0, fun() -> begin
    #  music_crossfaded.skip()
    #  music_4m_crossfaded.skip()
    #end)
    #thread.run(delay=2.0, fun() -> begin
    #  music_crossfaded.skip()
    #  music_4m_crossfaded.skip()
    #end)
    #thread.run(delay=5.0, fun() -> begin
    #  music_crossfaded.skip()
    #  music_4m_crossfaded.skip()
    #end)

  end
  ads.on_track(skip_music_on_ad_or_ad)

  # Outer switch with track_sensitive=false for immediate ads switching
  # Uses inner switches which handle crossfade selection
  #current_music_source = switch(track_sensitive=false, [
  #  ({current_loop() == "J" or current_loop() == "K" or current_loop() == "H" or current_loop() == "I"}, music_4m_inner),
  #  ({true}, music_inner)
  #])
  #current_music_source = music_inner
  #current_music_source = single("https://stagingtm.displayer25.com/uploads/assets/music/music/3331ef748090df7f674538d23d929283.mp3")
  #current_music_source = mksafe(single("https://stagingtm.displayer25.com/uploads/assets/music/music/3331ef748090df7f674538d23d929283.mp3"))

  current_music_source = switch(track_sensitive=false, [
    ({current_loop() == "J" or current_loop() == "K" or current_loop() == "H" or current_loop() == "I"}, music_4m_inner),
    ({true}, music_inner)
  ])

  # Ad Scheduler using specific predicates for all loops including J and K
  ad_selector = switch(track_sensitive=true, all_predicates=true, [
      # Loops A, B, J, K (4 ads per 5 mins)
      (predicate.at_most(4, {4m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {4m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {4m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {4m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {9m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {9m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {9m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {9m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {14m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {14m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {14m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {14m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {19m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {19m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {19m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {19m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {24m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {24m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {24m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {24m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {29m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {29m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {29m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {29m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {34m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {34m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {34m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {34m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {39m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {39m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {39m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {39m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {44m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {44m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {44m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {44m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {49m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {49m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {49m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {49m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {54m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {54m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {54m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {54m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {59m and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {59m15s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {59m30s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),
      (predicate.at_most(4, {59m45s and (current_loop() == "A" or current_loop() == "B" or current_loop() == "J" or current_loop() == "K")}), ads),



      # Loop C (3 ads per 5 mins)
      (predicate.at_most(3, {4m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {4m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {4m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {9m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {9m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {9m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {14m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {14m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {14m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {19m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {19m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {19m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {24m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {24m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {24m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {29m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {29m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {29m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {34m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {34m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {34m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {39m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {39m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {39m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {44m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {44m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {44m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {49m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {49m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {49m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {54m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {54m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {54m40s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {59m and current_loop() == "C"}), ads),
      (predicate.at_most(3, {59m20s and current_loop() == "C"}), ads),
      (predicate.at_most(3, {59m40s and current_loop() == "C"}), ads),

      # Loop D (3 ads per 10 mins)
      (predicate.at_most(3, {9m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {9m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {9m40s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {19m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {19m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {19m40s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {29m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {29m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {29m40s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {39m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {39m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {39m40s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {49m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {49m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {49m40s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {59m and current_loop() == "D"}), ads),
      (predicate.at_most(3, {59m20s and current_loop() == "D"}), ads),
      (predicate.at_most(3, {59m40s and current_loop() == "D"}), ads),


      # Loop E (3 ads per 15 mins)
      (predicate.at_most(3, {14m and current_loop() == "E"}), ads),
      (predicate.at_most(3, {14m20s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {14m40s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {29m and current_loop() == "E"}), ads),
      (predicate.at_most(3, {29m20s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {29m40s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {44m and current_loop() == "E"}), ads),
      (predicate.at_most(3, {44m20s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {44m40s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {59m and current_loop() == "E"}), ads),
      (predicate.at_most(3, {59m20s and current_loop() == "E"}), ads),
      (predicate.at_most(3, {59m40s and current_loop() == "E"}), ads)
  ])

 # ============================================================================
  # AUDIO ENHANCEMENT
  # ============================================================================

  # Apply different processing to music and ads to maintain ad loudness

  # Process music without crossfade first
  processed_music = current_music_source
  #processed_music = compress.exponential(mu=1.0, processed_music)
  #bypass normalisation
  #processed_music = compress.exponential(mu=1.0, processed_music)
  # Create the final stream with processed music and pre-processed ads
  # Ads already have amplification, compression, normalization, and limiting applied
  #processed_music = limit(threshold=-12.0, attack=0.001, release=0.05, processed_music)
  # Create a smart music source that fades out before ads
  # We'll monitor the time and apply fade/silence when ads are about to start

  # Variables for transition control
  play_ads_now = ref(false)
  fade_start_time = ref(-1.0)

  # Thread to monitor ad timing and control transitions
  thread.run(every=0.1, fun() -> begin
    secs_to_ads = seconds_until_ads()

    # Log timing
    if secs_to_ads >= 0 and secs_to_ads <= 10 then
      log("DEBUG: Seconds until ads: #{secs_to_ads}, fade_start: #{fade_start_time()}")
    end

    # Start fade 2 seconds before ads
    if secs_to_ads >= 0 and secs_to_ads <= 2 and fade_start_time() < 0.0 then
      fade_start_time := time.up()
      log("CRITICAL: Starting fade, ads in #{secs_to_ads} seconds")
    end

    # Switch to ads when ready and fade complete
    if source.is_ready(ad_selector) then
      if not play_ads_now() and fade_start_time() >= 0.0 then
        elapsed = time.up() - fade_start_time()
        if elapsed >= 2.0 then
          play_ads_now := true
          fade_start_time := -1.0
          log("CRITICAL: Switching to ads now")
        end
      end
    else
      # Reset when ads finish
      if play_ads_now() then
        # CRITICAL: Set post-ads flag BEFORE resetting play_ads_now
        just_finished_ads := true
        log("INFO: Post-ads source activated")

        play_ads_now := false
        fade_start_time := -1.0

        # CRITICAL: Skip the inner switches IMMEDIATELY to force them to re-evaluate
        # This must happen BEFORE the outer switch transitions back to music
        log("INFO: Forcing inner switches to re-select source after ads")
        music_inner.skip()
        music_4m_inner.skip()

        log("INFO: Ads finished, back to music")
      end
    end
  end)

  # Crossfade is now handled by the cross() function applied to music sources
  # Create static quieter versions of current music for fading out before ads
  music_90 = add(weights=[0.9, 0.1], [processed_music, blank()])
  music_80 = add(weights=[0.8, 0.2], [processed_music, blank()])
  music_70 = add(weights=[0.7, 0.3], [processed_music, blank()])
  music_60 = add(weights=[0.6, 0.4], [processed_music, blank()])
  music_50 = add(weights=[0.5, 0.5], [processed_music, blank()])
  music_40 = add(weights=[0.4, 0.6], [processed_music, blank()])
  music_30 = add(weights=[0.3, 0.7], [processed_music, blank()])
  music_20 = add(weights=[0.2, 0.8], [processed_music, blank()])
  music_10 = add(weights=[0.1, 0.9], [processed_music, blank()])
  music_0 = blank()

  # Create the smart music source with fade-out support before ads
  smart_music = switch(track_sensitive=false, [
    # Fade-out states (when fading to ads)
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 1.8}, music_0),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 1.6}, music_10),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 1.4}, music_20),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 1.2}, music_30),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 1.0}, music_40),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 0.8}, music_50),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 0.6}, music_60),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 0.4}, music_70),
    ({fade_start_time() >= 0.0 and time.up() - fade_start_time() >= 0.2}, music_80),
    ({fade_start_time() >= 0.0}, music_90),

    # Normal state (with automatic crossfading between tracks handled by cross() function)
    ({true}, processed_music)
  ])

  # Main switch without any transitions to avoid glitches
  radio_stream = switch(track_sensitive=false,
    [
      ({play_ads_now()}, ad_selector),
      ({true}, smart_music)
    ]
  )

  log("INFO: Separate audio processing applied - music normalized, ads pre-processed")


  # Prayer Time Integration
  
  #final_radio = switch(track_sensitive=false, [
  #  ({prayer_mute_enabled() and prayer_enabled() and is_prayer_time()}, blank(duration=2.0)),
  #  ({true}, radio_stream)
  #])
  final_radio = radio_stream

  # ============================================================================
  # EQUALIZER APPLICATION
  # ============================================================================

  # Apply EQ to final output (after all processing, before Icecast)
  #final_radio_eq = apply_eq_to_stream(final_radio)
  #final_radio_eq = final_radio
  log("INFO: EQ processing applied to final output")
  #final_output = final_radio_eq

  final_output = final_radio

  # Apply final normalization to ensure consistent output levels
  #final_output = normalize(target=-6., window=0.01, gain_min=-10., gain_max=6., final_radio_eq)
  log("INFO: Final normalization applied to output")

  # Output to Icecast
  out = output.icecast(%mp3(bitrate=int_of_string(icecast_bitrate())),
    host=icecast_host(), port=icecast_port(), mount=icecast_mount(),
    user=icecast_user(), password=icecast_pass(),
    fallible=false, final_output)

  ice_shutdown := [out.shutdown]
end




################################################################################
#                           HTTP ENDPOINTS                                    #
################################################################################

# Restart endpoint - reinitializes the entire playout chain
def req_restart(_, res)
  log("INFO: Restart request received for user: #{user_id()}")

  try
    # Retrieve and call icecast shutdown function
    shutdown_func = list.hd(ice_shutdown())
    shutdown_func()
    log("INFO: Icecast output stopped successfully")

    # Clear the shutdown list
    ice_shutdown := []

    # Re-initialize after delay to ensure clean shutdown
    thread.run(delay=2.0, init_playout_chain)
    log("INFO: Playout chain restart scheduled")

    res.status_code(200)
    res.status_message("SUCCESS: Script restart initiated for user: #{user_id()}")
  catch err do
    log("ERROR: Failed to restart script: #{err}")
    res.status_code(500)
    res.status_message("ERROR: Failed to restart script")
  end
end

# Shutdown endpoint - gracefully shuts down the liquidsoap script
def req_shutdown(_, res)
  log("INFO: Shutdown request received for user: #{user_id()}")

  # Schedule shutdown with delay to allow response
  thread.run(delay=1.0, shutdown)

  res.status_code(200)
  res.status_message("SUCCESS: Shutdown initiated for user: #{user_id()}")
end

# EQ preset GET endpoint - simplified to avoid type errors
def req_eq_preset_get(_, res)
  # Return current preset and available presets
  eq_json = "{" ^
    "\"current_preset\":\"#{eq_preset()}\"," ^
    "\"available_presets\":[\"flat\",\"vocal_boost\",\"bass_heavy\",\"bright\",\"warm\",\"radio_classic\",\"pop\",\"rock\",\"classical\"]," ^
    "\"eq_available\":#{string_of(eq_available())}" ^
    "}"

  res.status_code(200)
  res.content_type("application/json")
  res.status_message(eq_json)
end

# EQ preset POST endpoint - change EQ preset
def req_eq_preset_post(req, res)
  # Get preset from query parameter
  preset = req.query.preset

  if preset == "" then
    res.status_code(400)
    res.content_type("application/json")
    res.status_message("{\"error\":\"Missing preset parameter\"}")
  elsif list.mem(preset, ["flat", "vocal_boost", "bass_heavy", "bright", "warm", "radio_classic", "pop", "rock", "classical"]) then
    # Valid preset, update and save
    eq_preset := preset
    save_eq_preset()

    log("INFO: EQ preset changed to: #{preset}")

    # Return success response
    success_json = "{" ^
      "\"status\":\"success\"," ^
      "\"message\":\"EQ preset changed to #{preset}\"," ^
      "\"current_preset\":\"#{preset}\"" ^
      "}"

    res.status_code(200)
    res.content_type("application/json")
    res.status_message(success_json)
  else
    # Invalid preset
    error_json = "{" ^
      "\"error\":\"Invalid preset: #{preset}\"," ^
      "\"available_presets\":[\"flat\",\"vocal_boost\",\"bass_heavy\",\"bright\",\"warm\",\"radio_classic\",\"pop\",\"rock\",\"classical\"]" ^
      "}"

    res.status_code(400)
    res.content_type("application/json")
    res.status_message(error_json)
  end
end

# Health check endpoint
def req_health(_, res)
  # Create JSON response string manually since Liquidsoap doesn't support object literals
  status_json = "{" ^
    "\"user_id\":\"#{user_id()}\"," ^
    "\"current_loop\":\"#{current_loop()}\"," ^
    "\"played_ad_count\":#{played_ad_count()}," ^
    "\"icecast_host\":\"#{icecast_host()}\"," ^
    "\"icecast_port\":#{icecast_port()}," ^
    "\"icecast_mount\":\"#{icecast_mount()}\"," ^
    "\"prayer_times_count\":#{list.length(prayer_times())}," ^
    "\"prayer_enabled\":#{string_of(prayer_enabled())}," ^
    "\"prayer_mute_enabled\":#{string_of(prayer_mute_enabled())}," ^
    "\"is_prayer_time\":#{is_prayer_time()}," ^
    "\"eq_preset\":\"#{eq_preset()}\"," ^
    "\"eq_available\":#{string_of(eq_available())}" ^
    "}"

  res.status_code(200)
  res.content_type("application/json")
  res.status_message(status_json)
end

# Register HTTP endpoints
harbor.http.register(port=control_port(), method="GET", "/restart_#{user_id()}", req_restart)

harbor.http.register(port=control_port(), method="GET", "/shutdown_#{user_id()}", req_shutdown)
harbor.http.register(port=control_port(), method="GET", "/health_#{user_id()}", req_health)

# Register EQ endpoints
harbor.http.register(port=control_port(), method="GET", "/eq_preset_#{user_id()}", req_eq_preset_get)
#harbor.http.register(port=7000, method="POST", "/eq_preset_#{user_id()}", req_eq_preset_post)

log("INFO: HTTP endpoints registered on port #{control_port()}")

if api_token() != "" then
  log("INFO: Liquidsoap API auth mode: Bearer token enabled")
else
  log("WARNING: Liquidsoap API auth mode: token missing, running in legacy unauthenticated mode")
end
log("INFO: Available endpoints:")
log("INFO:   - GET /restart_#{user_id()} - Restart playout chain")
log("INFO:   - GET /shutdown_#{user_id()} - Shutdown script")
log("INFO:   - GET /health_#{user_id()} - Health check")
log("INFO:   - GET /eq_preset_#{user_id()} - Get current EQ preset")
log("INFO:   - POST /eq_preset_#{user_id()}?preset=<name> - Change EQ preset")
log("INFO: Available EQ presets: flat, vocal_boost, bass_heavy, bright, warm, radio_classic, pop, rock, classical")







################################################################################
#                           CLEANUP AND STARTUP                               #
################################################################################

# Cleanup function - removes PID file on shutdown
def cleanup()
  log("INFO: Performing cleanup operations...")
  try
    ignore(process.run("rm /home/oooomedia/liq_scripts/pids/#{user_id()}.pid"))
    log("INFO: PID file removed successfully")
  catch err do
    log("WARNING: Failed to remove PID file: #{err}")
  end
end

# Register cleanup function
on_shutdown(cleanup)

# Schedule prayer times refresh every hour
thread.run(every=3600.0, fetch_prayer_times)
log("INFO: Prayer times refresh scheduled every hour")

# Start the playout chain
  log("INFO: Starting main playout chain...")
  init_playout_chain()
  log("INFO: Liquidsoap scheduler fully initialized and running with prayer time support")