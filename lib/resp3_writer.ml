let crlf = "\r\n"

let write_bulk_string buf s =
  Buffer.add_char buf '$';
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_string buf crlf;
  Buffer.add_string buf s;
  Buffer.add_string buf crlf

let write_command buf args =
  Buffer.add_char buf '*';
  Buffer.add_string buf (string_of_int (Array.length args));
  Buffer.add_string buf crlf;
  Array.iter (write_bulk_string buf) args

let command_to_string args =
  let buf = Buffer.create 64 in
  write_command buf args;
  Buffer.contents buf
