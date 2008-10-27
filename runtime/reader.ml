open Codec

module type S =
sig
  type t
  type position

  val close : t -> unit

  val read_prefix : t -> prefix

  val read_vint : t -> int
  val read_bool : t -> bool
  val read_rel_int : t -> int
  val read_i8 : t -> int
  val read_i32 : t -> Int32.t
  val read_i64 : t -> Int64.t
  val read_float : t -> float
  val read_string : t -> string

  val offset : t -> int -> position
  val skip_to : t -> position -> unit

  val skip_value : t -> prefix -> unit
end

type reader_func =
    [
      `Offset | `Skip_to | `Read_prefix
      | `Read_vint | `Read_bool | `Read_rel_int | `Read_io | `Read_i8
      | `Read_i32 | `Read_i64 | `Read_float | `Read_string
    ]

let string_of_reader_func : reader_func -> string = function
  `Offset -> "offset"
  | `Skip_to -> "skip_to"
  | `Read_prefix -> "read_prefix"
  | `Read_vint -> "read_vint"
  | `Read_bool -> "read_bool"
  | `Read_rel_int -> "read_rel_int"
  | `Read_io -> "read_io"
  | `Read_i8 -> "read_i8"
  | `Read_i32 -> "read_i32"
  | `Read_i64 -> "read_i64"
  | `Read_float -> "read_float"
  | `Read_string -> "read_string"

DEFINE Read_vint(t) =
  let b = ref (read_byte t) in
  let x = ref 0 in
  let e = ref 0 in
    while !b >= 128 do
      x := !x + ((!b - 128) lsl !e);
      e := !e + 7;
      b := read_byte t
    done;
    !x + (!b lsl !e)

module String_reader : sig
  include S
  val make : string -> int -> int -> t
  val close : t -> unit
end =
struct
  type t = { mutable buf : string; mutable last : int; mutable pos : int }
  type position = int

  let make s off len =
    if off < 0 || len < 0 || off + len > String.length s then
      invalid_arg "Reader.String_reader.make";
    { buf = s; pos = off; last = off + len }

  let close t = (* invalidate reader *)
    t.buf <- "";
    t.pos <- 1;
    t.last <- 0

  let read_byte t =
    let pos = t.pos in
      if pos >= t.last then raise End_of_file;
      let r = Char.code (String.unsafe_get t.buf pos) in
        t.pos <- t.pos + 1;
        r

  let read_bytes t buf off len =
    if off < 0 || len < 0 || off + len > String.length buf then
      invalid_arg "Reader.String_reader.read_bytes";
    if len > t.last - t.pos then raise End_of_file;
    String.blit t.buf t.pos buf off len;
    t.pos <- t.pos + len

  let read_vint t = Read_vint(t)

  let skip_value t p = match ll_type p with
      Vint  -> ignore (read_vint t)
    | Bits8 -> t.pos <- t.pos + 1
    | Bits32 -> t.pos <- t.pos + 4
    | Bits64_long | Bits64_float -> t.pos <- t.pos + 8
    | Tuple | Htuple | Bytes -> let len = read_vint t in t.pos <- t.pos + len

  let offset t off =
    let pos = off + t.pos in
    (* only check if > because need to be able to skip to EOF, but not "past" it *)
      if off < 0 then invalid_arg "Extprot.Reader.String_reader.offset";
      if pos > t.last then raise End_of_file;
      pos

  let skip_to t pos =
    if pos > t.last then raise End_of_file;
    if pos > t.pos then t.pos <- pos

  INCLUDE "reader_impl.ml"
end

module IO_reader : sig
  include S
  val from_io : IO.input -> t
  val from_string : string -> t
  val from_file : string -> t
end =
struct
  type t = { io : IO.input; mutable pos : int }
  type position = int

  let from_io io = { io = io; pos = 0 }
  let from_string s = { io = IO.input_string s; pos = 0 }
  let from_file fname = from_io (IO.input_channel (open_in fname))

  let close t = IO.close_in t.io

  let offset t off =
    if off < 0 then invalid_arg "Extprot.Reader.IO_reader.offset";
    t.pos + off

  let read_byte t =
    let b = IO.read_byte t.io in
      t.pos <- t.pos + 1;
      b

  let read_bytes t buf off len =
    if off < 0 || len < 0 || off + len > String.length buf then
      invalid_arg "Reader.IO_reader.read_bytes";
    let n = IO.really_input t.io buf off len in
      t.pos <- t.pos + n;
      if n <> len then raise End_of_file

  let read_vint t = Read_vint(t)

  let skip_buf = String.create 4096

  let rec skip_n t = function
      0 -> ()
    | n -> let len = min n (String.length skip_buf) in
        read_bytes t skip_buf 0 len;
        skip_n t (n - len)

  let skip_value t p = match ll_type p with
      Vint -> ignore (read_vint t)
    | Bits8 -> ignore (read_byte t)
    | Bits32 -> ignore (read_bytes t skip_buf 0 4)
    | Bits64_float | Bits64_long -> ignore (read_bytes t skip_buf 0 8)
    | Tuple | Htuple | Bytes -> skip_n t (read_vint t)

  let skip_to t pos = if t.pos < pos then skip_n t (pos - t.pos)

  INCLUDE "reader_impl.ml"
  DEFINE EOF_wrap(f, x) = try f x with IO.No_more_input -> raise End_of_file

  let read_prefix t = EOF_wrap(read_prefix, t)
  let read_vint t = EOF_wrap(read_vint, t)
  let read_bool t = EOF_wrap(read_bool, t)
  let read_rel_int t = EOF_wrap(read_rel_int, t)
  let read_i8 t = EOF_wrap(read_i8, t)
  let read_i32 t = EOF_wrap(read_i32, t)
  let read_i64 t = EOF_wrap(read_i64, t)
  let read_float t = EOF_wrap(read_float, t)
  let read_string t = EOF_wrap(read_string, t)
end
