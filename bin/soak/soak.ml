(* Long-running stability soak.

   Runs a steady command workload (GET/SET/DEL mix) across N fibers
   against either standalone Valkey or a cluster. Every
   [--sample-interval] seconds it captures three metrics:

     heap_words   : Gc.quick_stat ().Gc.heap_words     — resident heap
     fd_count     : fd count from /proc/self/fd        — file descriptors
     ops_issued   : total ops completed so far         — sanity floor

   At the end it prints the full sample table, then computes a simple
   linear regression over the last ~80% of samples and fails if the
   heap_words slope exceeds [--heap-slope-max] words/sample or the
   fd_count slope exceeds [--fd-slope-max] fds/sample.

   CI-friendly short window: [--seconds 300 --sample-interval 10].
   Long local run: [--seconds 43200 --sample-interval 60] (12 h).

   Intentionally minimal: no chaos, no tail-latency report, no bucket
   histograms. [bin/fuzz/] covers those. This tool exists to catch
   slow leaks only. *)

module VC = Valkey.Client
module CR = Valkey.Cluster_router
module VConn = Valkey.Connection

type target =
  | Standalone of { host : string; port : int }
  | Cluster of { seeds : (string * int) list }

type args = {
  target : target;
  seconds : int;                  (* total soak duration *)
  workers : int;                  (* concurrent fibers issuing ops *)
  keys : int;                     (* distinct keys in workload *)
  sample_interval : int;          (* seconds between samples *)
  heap_slope_max : float;         (* words/sample *)
  fd_slope_max : float;           (* fds/sample *)
  strict : bool;                  (* exit 1 on threshold breach *)
}

let default_args = {
  target = Standalone { host = "localhost"; port = 6379 };
  seconds = 300;
  workers = 16;
  keys = 256;
  sample_interval = 10;
  heap_slope_max = 5_000.0;       (* ~40 KiB/sample creep allowed *)
  fd_slope_max = 0.05;            (* < 1 fd per 20 samples *)
  strict = false;
}

let parse_seeds s =
  String.split_on_char ',' s
  |> List.filter (fun x -> x <> "")
  |> List.map (fun pair ->
         match String.split_on_char ':' pair with
         | [ host; port ] -> host, int_of_string port
         | _ -> failwith ("bad seed: " ^ pair))

let parse_args () =
  let a = ref default_args in
  let specs =
    [ "--host",
        Arg.String (fun h ->
          a := { !a with target = Standalone { host = h; port = 6379 } }),
      " standalone host (default localhost)";
      "--port",
        Arg.Int (fun p ->
          match !a.target with
          | Standalone { host; _ } ->
              a := { !a with target = Standalone { host; port = p } }
          | _ -> ()),
      "N standalone port (default 6379)";
      "--seeds",
        Arg.String (fun s ->
          a := { !a with target = Cluster { seeds = parse_seeds s } }),
      "host1:port1,host2:port2 use cluster";
      "--seconds", Arg.Int (fun n -> a := { !a with seconds = n }),
      "N total duration (default 300)";
      "--workers", Arg.Int (fun n -> a := { !a with workers = n }),
      "N concurrent fibers (default 16)";
      "--keys", Arg.Int (fun n -> a := { !a with keys = n }),
      "N distinct keys (default 256)";
      "--sample-interval", Arg.Int (fun n ->
        a := { !a with sample_interval = n }),
      "N seconds between samples (default 10)";
      "--heap-slope-max", Arg.Float (fun x ->
        a := { !a with heap_slope_max = x }),
      "N words/sample threshold (default 5000)";
      "--fd-slope-max", Arg.Float (fun x ->
        a := { !a with fd_slope_max = x }),
      "N fds/sample threshold (default 0.05)";
      "--strict", Arg.Unit (fun () -> a := { !a with strict = true }),
      " exit 1 if slope thresholds are breached";
    ]
  in
  Arg.parse specs (fun _ -> ()) "valkey-soak [OPTIONS]";
  !a

(* ---------- sampler ---------- *)

type sample = {
  t_sec : float;
  heap_words : int;
  top_heap_words : int;
  live_words : int;
  fd_count : int;
  ops : int;
}

let fd_count () =
  (* Linux-only: count entries in /proc/self/fd. Returns 0 on
     platforms without /proc (macOS CI runners). Don't fail the
     whole soak on a missing /proc. *)
  try
    let d = Unix.opendir "/proc/self/fd" in
    let n = ref 0 in
    (try
       while true do
         let _ = Unix.readdir d in
         incr n
       done
     with End_of_file -> ());
    Unix.closedir d;
    !n - 2  (* subtract . and .. *)
  with _ -> 0

let take_sample ~t0 ~ops =
  let gc = Gc.quick_stat () in
  { t_sec = Unix.gettimeofday () -. t0;
    heap_words = gc.heap_words;
    top_heap_words = gc.top_heap_words;
    live_words = gc.live_words;
    fd_count = fd_count ();
    ops }

let print_sample_header () =
  Printf.printf
    "%7s  %11s  %11s  %11s  %8s  %12s\n"
    "t (s)" "heap_words" "top_heap" "live_words" "fd_count" "ops"

let print_sample s =
  Printf.printf
    "%7.1f  %11d  %11d  %11d  %8d  %12d\n"
    s.t_sec s.heap_words s.top_heap_words s.live_words
    s.fd_count s.ops

(* Ordinary least-squares slope over [(x, y)] pairs. Returns the
   slope in units of y per unit x. Used on y = heap_words and
   y = fd_count, with x = sample index (not wall time), so the
   units are words-per-sample and fds-per-sample. *)
let slope samples proj =
  let n = List.length samples in
  if n < 2 then 0.0
  else
    let xs = List.mapi (fun i _ -> float_of_int i) samples in
    let ys = List.map (fun s -> float_of_int (proj s)) samples in
    let mean l = List.fold_left ( +. ) 0.0 l /. float_of_int n in
    let mx = mean xs in
    let my = mean ys in
    let num =
      List.fold_left2 (fun acc x y -> acc +. (x -. mx) *. (y -. my))
        0.0 xs ys
    in
    let den =
      List.fold_left (fun acc x -> acc +. (x -. mx) ** 2.0) 0.0 xs
    in
    if den = 0.0 then 0.0 else num /. den

(* ---------- workload ---------- *)

let run_workload_fiber ~client ~clock ~keys ~deadline ~ops_counter ~i =
  let rng = Random.State.make [| i; 0xCAFE |] in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then ()
    else begin
      let k =
        Printf.sprintf "soak:%d" (Random.State.int rng keys)
      in
      let v = Printf.sprintf "v-%d-%d" i (Random.State.int rng 1_000_000) in
      (match VC.set client k v with
       | Ok _ -> ()
       | Error _ -> ());
      (match VC.get client k with
       | Ok _ -> ()
       | Error _ -> ());
      if Random.State.int rng 10 = 0 then
        (match VC.del client [ k ] with
         | Ok _ -> ()
         | Error _ -> ());
      Atomic.incr ops_counter;
      (* Small yield every iteration to cooperate with the sampler
         fiber. *)
      Eio.Fiber.yield ();
      ignore clock;
      loop ()
    end
  in
  loop ()

(* ---------- main ---------- *)

let build_client ~env ~sw args =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match args.target with
  | Standalone { host; port } ->
      VC.connect ~sw ~net ~clock
        ~config:VC.Config.default ~host ~port ()
  | Cluster { seeds } ->
      let config =
        { (CR.Config.default ~seeds) with prefer_hostname = true }
      in
      match CR.create ~sw ~net ~clock ~config () with
      | Error e -> failwith ("cluster_router: " ^ e)
      | Ok router -> VC.from_router ~config:VC.Config.default router

let () =
  let args = parse_args () in
  Printf.printf
    "== valkey-soak: %ds / %d workers / %d keys / sample every %ds ==\n"
    args.seconds args.workers args.keys args.sample_interval;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let client = build_client ~env ~sw args in
  let t0 = Unix.gettimeofday () in
  let deadline = t0 +. float_of_int args.seconds in
  let ops_counter = Atomic.make 0 in
  let samples = ref [] in

  (* Sampler fiber. Produces a sample every [sample_interval] s
     until the deadline. *)
  let sampler () =
    print_sample_header ();
    (* Take an initial sample before any ops land so the slope
       compares steady-state, not cold-start. *)
    let s0 = take_sample ~t0 ~ops:0 in
    samples := [ s0 ];
    print_sample s0;
    let rec loop () =
      if Unix.gettimeofday () >= deadline then ()
      else begin
        Eio.Time.sleep clock (float_of_int args.sample_interval);
        let s =
          take_sample ~t0 ~ops:(Atomic.get ops_counter)
        in
        samples := s :: !samples;
        print_sample s;
        loop ()
      end
    in
    loop ()
  in

  (* Workers + sampler race the deadline. *)
  Eio.Fiber.all
    ([ sampler ]
     @ List.init args.workers (fun i () ->
           run_workload_fiber ~client ~clock
             ~keys:args.keys ~deadline ~ops_counter ~i));

  VC.close client;
  let ordered = List.rev !samples in
  let n = List.length ordered in
  let tail_start = max 1 (n / 5) in
  let tail =
    List.filteri (fun i _ -> i >= tail_start) ordered
  in
  let heap_slope = slope tail (fun s -> s.heap_words) in
  let fd_slope = slope tail (fun s -> s.fd_count) in
  let ops_total = Atomic.get ops_counter in

  Printf.printf "\n== slopes over last %d samples ==\n"
    (List.length tail);
  Printf.printf "  heap_words:  %+.2f / sample  (threshold %+.2f)\n"
    heap_slope args.heap_slope_max;
  Printf.printf "  fd_count:    %+.2f / sample  (threshold %+.2f)\n"
    fd_slope args.fd_slope_max;
  Printf.printf "  ops_issued:  %d total (%.0f ops/s)\n"
    ops_total
    (float_of_int ops_total /. float_of_int args.seconds);

  let heap_breach = heap_slope > args.heap_slope_max in
  let fd_breach = fd_slope > args.fd_slope_max in
  if heap_breach then
    Printf.printf
      "  ** heap slope exceeds threshold — possible leak **\n";
  if fd_breach then
    Printf.printf
      "  ** fd slope exceeds threshold — possible descriptor leak **\n";
  if args.strict && (heap_breach || fd_breach) then exit 1
