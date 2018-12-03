structure Server = struct
type Req = { cmd : string, path : string, headers : (string*string) list }
type Resp = { status : int, headers : (string*string) list, body : Word8Vector.vector }
exception BadRequest
exception NotFound of string

fun collect mark i sepLen acc slc =
    if i > (mark + sepLen) then
         (Word8VectorSlice.subslice (slc, mark, SOME ((i-mark)-sepLen)))::acc
    else acc

fun recur s l len sepLen mark i [] acc =
    recur s l len sepLen i i l (collect mark i sepLen acc s)
  | recur s l len sepLen mark i (b::bs) acc =
    if i = len then List.rev (collect mark i 0 acc s)
    else recur s l len sepLen mark (i+1)
         (if b = Word8VectorSlice.sub (s, i) then bs else l) acc

fun tokens slc (sep : string) =
    let val lst = map (Word8.fromInt o Char.ord) (String.explode sep)
        val len = Word8VectorSlice.length slc
        val sepLen = String.size sep
    in recur slc lst len sepLen 0 0 lst [] end

val sliceToStr = Byte.bytesToString o Word8VectorSlice.vector
fun tokens' slc (sep : string) = map sliceToStr (tokens slc sep)

fun parseHeaders nil = nil
  | parseHeaders (ln::lns) = (case tokens' ln ": " of
                                  k::v::_ => (k,v)
                                | _ => raise BadRequest) :: (parseHeaders lns)

fun writeHeaders nil = ""
  | writeHeaders ((k,v)::hs) = k ^ ": " ^ v ^ "\r\n" ^ (writeHeaders hs)

fun parseReq slc : Req =
    case tokens slc "\r\n" of
        nil => raise BadRequest
      | lines as (hd::tl) =>
        case tokens' hd " " of
            "GET"::path::_ => { cmd = "GET", path = path, headers = parseHeaders tl }
          | _ => raise BadRequest

fun needUpgrade req = false (*TODO*)

fun sendBytes sock bytes = ignore (Socket.sendVec (sock, Word8VectorSlice.full bytes))
fun sendStr sock str = sendBytes sock (Byte.stringToBytes str)
fun sendList sock lst = sendStr sock (String.concat lst)

fun fileResp filePath =
    let val stream = BinIO.openIn filePath
        val data = BinIO.inputAll stream
        val () = BinIO.closeIn stream
    in { status = 200,
         headers = [("Content-Type", "text/html"),
                    ("Content-Length", Int.toString (Word8Vector.length data))],
         body = data }
    end

fun respCode 200 = "OK"
  | respCode 400 = "Bad Request"
  | respCode 404 = "Not Found"
  | respCode _ = "Internal Server Error"

fun sendResp sock {status=status,headers=headers,body=body} =
    (sendList sock ["HTTP/1.1 ", Int.toString status, " ", respCode status, "\r\n",
                    writeHeaders headers, "\r\n"];
     sendBytes sock body)

fun sendError sock code body =
    (print body;
     sendResp sock {status=code,headers=[],body=Byte.stringToBytes body};
     Socket.close sock)

fun serve sock : Resp =
    let
        val req = parseReq (Word8VectorSlice.full (Socket.recvVec (sock, 2048)))
        val path = #path req
        val reqPath = case path of
                          "/" => "/index"
                        | p => if String.isPrefix "/ws" p
                               then String.extract (p, 3, NONE)
                               else p
    in
        if needUpgrade req then
            raise BadRequest (*TODO*)
        else (fileResp ("static/html" ^ reqPath ^ ".html"))
             handle Io => (fileResp (String.extract (path, 1, NONE))) handle Io => raise NotFound path
    end

fun connMain sock =
    (case serve sock of
         resp => sendResp sock resp; Socket.close sock)
    handle BadRequest    => sendError sock 400 "Bad Request\n"
         | NotFound path => sendError sock 404 ("Not Found: "^path^"\n")

fun acceptLoop server_sock =
    let val (s, _) = Socket.accept server_sock
    in
        print "Accepted a connection.\n";
        CML.spawn (fn () => connMain(s));
        acceptLoop server_sock
    end

fun run (program_name, arglist) =
    let val s = INetSock.TCP.socket()
    in
        Socket.Ctl.setREUSEADDR (s, true);
        Socket.bind(s, INetSock.any 8989);
        Socket.listen(s, 5);
        print "Entering accept loop...\n";
        acceptLoop s
    end

end
