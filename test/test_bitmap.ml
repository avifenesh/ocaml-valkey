(* Bitmap command tests — one per typed wrapper. Against the
   standalone Valkey at :6379. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let host = "localhost"
let port = 6379
let err_pp = E.pp

let with_client f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let c = C.connect ~sw ~net ~clock ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close c) (fun () -> f c)

let check_int msg expected actual =
  Alcotest.(check int) msg expected actual

let check_ok msg = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %a" msg err_pp e

let test_setbit_and_getbit () =
  with_client @@ fun c ->
  let k = "bm:sb" in
  ignore (C.del c [ k ]);
  let prev = check_ok "SETBIT first" (C.setbit c k ~offset:7 ~value:C.B1) in
  Alcotest.(check bool) "previous was 0" true (prev = C.B0);
  let prev2 = check_ok "SETBIT flip" (C.setbit c k ~offset:7 ~value:C.B0) in
  Alcotest.(check bool) "previous was 1" true (prev2 = C.B1);
  let b = check_ok "GETBIT" (C.getbit c k ~offset:7) in
  Alcotest.(check bool) "cleared bit is B0" true (b = C.B0);
  (* Past end of string / nonexistent key -> B0. *)
  let far = check_ok "GETBIT far" (C.getbit c k ~offset:1_000_000) in
  Alcotest.(check bool) "far-offset is B0" true (far = C.B0);
  ignore (C.del c [ k ])

let test_bitcount () =
  with_client @@ fun c ->
  let k = "bm:bc" in
  ignore (C.del c [ k ]);
  (* SET to "foobar" — known bit-count reference from the docs:
     foobar has 26 set bits across 6 bytes. *)
  ignore (C.set c k "foobar");
  let total = check_ok "BITCOUNT full" (C.bitcount c k) in
  check_int "foobar bitcount" 26 total;
  let first_byte =
    check_ok "BITCOUNT first byte"
      (C.bitcount c k ~range:(C.From_to { start = 0; end_ = 0 }))
  in
  check_int "'f' has 4 bits" 4 first_byte;
  let bit_slice =
    check_ok "BITCOUNT BIT range"
      (C.bitcount c k
         ~range:(C.From_to_unit
                   { start = 5; end_ = 30; unit = C.Bit }))
  in
  (* Per docs: returns 17 for this slice on "foobar". *)
  check_int "bit slice" 17 bit_slice;
  (* Non-existent key returns 0. *)
  let missing = check_ok "BITCOUNT missing" (C.bitcount c "bm:none") in
  check_int "missing = 0" 0 missing;
  ignore (C.del c [ k ])

let test_bitpos () =
  with_client @@ fun c ->
  let k = "bm:bp" in
  ignore (C.del c [ k ]);
  (* "\xff\xf0\x00" — first byte all ones, middle half ones, last
     all zeros. First 0 bit should be at position 12. *)
  ignore (C.set c k "\xff\xf0\x00");
  let pos_of_0 = check_ok "BITPOS 0" (C.bitpos c k ~bit:C.B0) in
  check_int "first 0 at bit 12" 12 pos_of_0;
  let pos_of_1 = check_ok "BITPOS 1" (C.bitpos c k ~bit:C.B1) in
  check_int "first 1 at bit 0" 0 pos_of_1;
  (* With explicit end range and no match -> -1. *)
  let none =
    check_ok "BITPOS 1 in all-zero range"
      (C.bitpos c k ~bit:C.B1
         ~range:(C.From_to { start = 2; end_ = 2 }))
  in
  check_int "no 1 in byte 2 -> -1" (-1) none;
  ignore (C.del c [ k ])

let test_bitop () =
  with_client @@ fun c ->
  let src1 = "{bm}:src1" and src2 = "{bm}:src2" and dst = "{bm}:dst" in
  ignore (C.del c [ src1; src2; dst ]);
  ignore (C.set c src1 "abc");
  ignore (C.set c src2 "abd");
  let size =
    check_ok "BITOP AND"
      (C.bitop c (C.Bitop_and [ src1; src2 ]) ~destination:dst)
  in
  check_int "dst size equals source size" 3 size;
  let and_value =
    check_ok "GET AND result" (C.get c dst)
  in
  (* "abc" AND "abd" = byte 0 'a' & 'a' = 'a', byte 1 'b' & 'b' = 'b',
     byte 2 'c' & 'd' = 0x60 = '`'. *)
  Alcotest.(check (option string)) "AND result" (Some "ab`") and_value;
  (* XOR of identical strings is all zeros. *)
  let _ = C.bitop c (C.Bitop_xor [ src1; src1 ]) ~destination:dst in
  let xor_val = check_ok "GET XOR result" (C.get c dst) in
  Alcotest.(check (option string)) "XOR same -> zeros"
    (Some "\x00\x00\x00") xor_val;
  (* NOT is unary per the typed constructor — the type system
     prevents a multi-source NOT at compile time. *)
  let _ = C.bitop c (C.Bitop_not src1) ~destination:dst in
  let not_val = check_ok "GET NOT result" (C.get c dst) in
  (* 'a' = 0x61, ~0x61 = 0x9E = '\x9e'. *)
  (match not_val with
   | Some s when String.length s = 3
                 && Char.code s.[0] = 0x9E -> ()
   | _ -> Alcotest.fail "NOT result mismatch");
  ignore (C.del c [ src1; src2; dst ])

let test_bitfield_get_set_incr () =
  with_client @@ fun c ->
  let k = "bm:bf" in
  ignore (C.del c [ k ]);
  let ops =
    [ C.Set { ty = C.Unsigned 8; at = C.Scaled_offset 0;
              value = 100L };
      C.Incrby { ty = C.Unsigned 8; at = C.Scaled_offset 0;
                 increment = 50L };
      C.Get { ty = C.Unsigned 8; at = C.Scaled_offset 0 };
    ]
  in
  match C.bitfield c k ops with
  | Error e -> Alcotest.failf "BITFIELD: %a" err_pp e
  | Ok replies ->
      check_int "reply count" 3 (List.length replies);
      (match replies with
       | [ Some 0L; Some 150L; Some 150L ] -> ()
       | _ ->
           let s =
             List.map
               (function Some n -> Int64.to_string n | None -> "nil")
               replies
             |> String.concat ", "
           in
           Alcotest.failf "unexpected: [%s]" s);
      ignore (C.del c [ k ])

let test_bitfield_overflow_fail () =
  with_client @@ fun c ->
  let k = "bm:bfof" in
  ignore (C.del c [ k ]);
  (* u8 = 0..255. Set to 250, then INCRBY 10 under OVERFLOW FAIL
     → nil, value unchanged. *)
  let ops =
    [ C.Set { ty = C.Unsigned 8; at = C.Scaled_offset 0;
              value = 250L };
      C.Overflow C.Fail;
      C.Incrby { ty = C.Unsigned 8; at = C.Scaled_offset 0;
                 increment = 10L };
      C.Get { ty = C.Unsigned 8; at = C.Scaled_offset 0 };
    ]
  in
  match C.bitfield c k ops with
  | Error e -> Alcotest.failf "BITFIELD: %a" err_pp e
  | Ok replies ->
      (* Overflow produces NO reply element. So we expect 3 entries:
         Set = previous (0), Incrby = nil (overflow), Get = 250. *)
      check_int "reply count (Overflow has no reply)" 3
        (List.length replies);
      (match replies with
       | [ Some 0L; None; Some 250L ] -> ()
       | _ ->
           let s =
             List.map
               (function Some n -> Int64.to_string n | None -> "nil")
               replies
             |> String.concat ", "
           in
           Alcotest.failf "unexpected: [%s]" s);
      ignore (C.del c [ k ])

let test_bitfield_ro () =
  with_client @@ fun c ->
  let k = "bm:bfro" in
  ignore (C.del c [ k ]);
  let _ =
    C.bitfield c k
      [ C.Set { ty = C.Signed 16; at = C.Scaled_offset 0;
                value = -42L } ]
  in
  (match C.bitfield_ro c k
           ~gets:[ C.Signed 16, C.Scaled_offset 0 ] with
   | Error e -> Alcotest.failf "BITFIELD_RO: %a" err_pp e
   | Ok [ -42L ] -> ()
   | Ok xs ->
       Alcotest.failf "unexpected: [%s]"
         (String.concat ", " (List.map Int64.to_string xs)));
  ignore (C.del c [ k ])

let tests =
  [ Alcotest.test_case "SETBIT / GETBIT round-trip" `Quick
      test_setbit_and_getbit;
    Alcotest.test_case "BITCOUNT full + byte range + bit range"
      `Quick test_bitcount;
    Alcotest.test_case "BITPOS forward + bounded no-match" `Quick
      test_bitpos;
    Alcotest.test_case "BITOP AND / XOR / NOT (unary typed)" `Quick
      test_bitop;
    Alcotest.test_case "BITFIELD SET + INCRBY + GET" `Quick
      test_bitfield_get_set_incr;
    Alcotest.test_case "BITFIELD OVERFLOW FAIL returns nil" `Quick
      test_bitfield_overflow_fail;
    Alcotest.test_case "BITFIELD_RO GET signed" `Quick
      test_bitfield_ro;
  ]
