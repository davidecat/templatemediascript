#!/usr/bin/liquidsoap

################################################################################
#                           LIQUIDSOAP SCHEDULER SCRIPT                       #
################################################################################

# Parse command line arguments
user_id = ref(argv(default="fail", 1))

if user_id() == "fail" then
  shutdown()
end

# Configuration
settings.init.daemon.set(bool_of_string(argv(default="true", 2)))
settings.init.daemon.pidfile.path.set("/home/oooomedia/liq_scripts/pids/#{user_id()}.pid")
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

def fetch_prayer_times()
  try
    result = http.get("https://stagingtm.displayer25.com/api/prayer")
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
  result = http.get(uri)
  log("DEBUG API Response from #{uri}: #{result}")
  let json.parse (j: {status: int, data: {icecast: {host: string, port: string, user: string, pass: string, mount: string, bitrate: string}, loop: string, asset_path: string}}) = result
  j
end

def add_track(stream)
  j = api_call(base_uri()^"/#{stream}")
  current_loop := j.data.loop
  # CRITICAL: Force start at 0.0 and ignore blank skipping
  track_uri = if stream == "music" or stream == "4minutesmusic" then
    'autocue:annotate:liq_cue_in=0.0,liq_blankskip=0.0,liq_cue_file=false:'^j.data.asset_path
  else
    'autocue:annotate:liq_cue_file=false,liq_blankskip=0.0:'^j.data.asset_path
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
  fetch_prayer_times()

  music = request.dynamic(id="music", prefetch=1, {add_track("music")})
  music_4m = request.dynamic(id="4minutesmusic", prefetch=1, {add_track("4minutesmusic")})
  ads = request.dynamic(id="ads", prefetch=2, {add_track("ad")})
# Refresh Logic: We wrap the ads in a buffer.
  # 'buffer=10.0' prepares 10 seconds of audio in memory.
  # 'max=12.0' ensures the buffer doesn't grow too large with old data.
  ads = buffer(buffer=10.0, max=12.0, ads)

  # Skip Logic: Clears the background music while ads are playing
  def skip_music_on_ad_or_ad(_)
    # We wait 2 seconds for the transition to finish before skipping [cite: 142]
    thread.run(delay=2.0, fun() -> begin
      log("INFO: Flushing music background for fresh restart")
      if current_loop() == "J" or current_loop() == "K" then
        music_4m.skip()
      else
        music.skip()
      end
    end)
  end
  ads.on_track(skip_music_on_ad_or_ad)

  # Determine current music source based on loop type [cite: 146]
  current_music_source = switch(track_sensitive=false, [
    ({current_loop() == "J" or current_loop() == "K"}, music_4m),
    ({true}, music)
  ])

  # Ad Scheduler using specific predicates for all loops including J and K [cite: 147-167]
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

  # Final Sequential Stream with Fade Transition
  radio_stream = switch(track_sensitive=false,
    transitions=[fun(old, new) -> add([fade.out(duration=0.5, old), fade.in(duration=0.5, new)])],
    [
      ({source.is_ready(ad_selector)}, ad_selector),
      ({true}, current_music_source)
    ]
  )

  # Prayer Time Integration
  final_radio = switch(track_sensitive=false, [
    ({prayer_enabled() and is_prayer_time()}, blank(duration=2.0)),
    ({true}, radio_stream)
  ])

  # Output to Icecast
  out = output.icecast(%mp3(bitrate=int_of_string(icecast_bitrate())),
    host=icecast_host(), port=icecast_port(), mount=icecast_mount(),
    user=icecast_user(), password=icecast_pass(),
    fallible=true, final_radio)

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
    "\"is_prayer_time\":#{is_prayer_time()}" ^
    "}"

  res.status_code(200)
  res.content_type("application/json")
  res.status_message(status_json)
end

# Register HTTP endpoints
harbor.http.register(port=7000, method="GET", "/restart_#{user_id()}", req_restart)
harbor.http.register(port=7000, method="GET", "/shutdown_#{user_id()}", req_shutdown)
harbor.http.register(port=7000, method="GET", "/health_#{user_id()}", req_health)

log("INFO: HTTP endpoints registered on port 7000")
log("INFO: Available endpoints:")
log("INFO:   - GET /restart_#{user_id()} - Restart playout chain")
log("INFO:   - GET /shutdown_#{user_id()} - Shutdown script")
log("INFO:   - GET /health_#{user_id()} - Health check")







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
