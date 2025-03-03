package sys.db;

import haxe.crypto.Sha256;
import haxe.crypto.Hmac;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.Input;

import sys.db.pgsql.DataType;
import sys.net.Host;
import sys.net.Socket;

using haxe.crypto.Md5;
using sys.db.pgsql.ByteTools;
using sys.db.pgsql.Messages;

class Postgres {
	public static function connect( params : {
		host     : String,
		?port    : Int,
		user     : String,
		pass     : String,
		?socket  : String,
		database : String
	} ) : Connection {
		return new PostgresConnection(params);
	}
}

class PostgresConnection implements sys.db.Connection {
	var status              : Map<String, String>;
	var process_id          : Int;
	var secret_key          : Int;
	var socket              : Socket;
	var last_insert_id      : Int;

	var current_data_iterator     : Iterator<Array<Bytes>>;
	var current_complete_iterator : Iterator<CommandComplete>;
	var current_message           : ServerMessage;

	var sasl_client_first_message: 	String;
	var sasl_server_first_message: 	String;

	var sasl_auth_message:			String;
	var sasl_salted_password:		haxe.io.Bytes;

	var auth_mode			: String = null;

	public function new( params : {
		database : String,
		host     : String,
		pass     : String,
		?port    : Int,
		?socket  : String,
		user     : String,
	}){
		if (params.port == null) params.port = 5432;
		status = new Map();
		socket = new Socket();
		socket.input.bigEndian = true;
		//socket.output.bigEndian = true;
		var h = new Host(params.host);
		socket.connect(h, params.port);
		// this is the current data row iterator for the result.
		current_data_iterator = [].iterator();

		// A request can have multiple command complete responses,
		// this tracks them as an iterator.
		current_complete_iterator = [].iterator();

		// write the startup message
		writeMessage(
				StartupMessage({
					user     : params.user,
					database : params.database,
					// client_encoding: "'utf-8'" // default
				})
		);

		// grab the next few optional status/data messages
		while (true) {
			switch readMessage() {
				case AuthenticationRequest(request_type) : {
					switch(request_type){
						case AuthenticationOk : null; //ok
						case AuthenticationCleartextPassword :
							writeMessage(PasswordMessage(params.pass));
						case AuthenticationMD5Password(salt) :
							writeMessage(PasswordMessage(md5Auth({
								pass : params.pass,
								user : params.user,
								salt : salt
							})));
						case AuthenticationSASL(auth_data) :
							// @todo: Handle case where we're offered multiple SASL modes.
							auth_mode = auth_data;
							var nonce = "todo";

							sasl_client_first_message = 'n,,n=${params.user},r=${nonce}';
							writeMessage(SASLInitialResponse( auth_data, sasl_client_first_message )); 
						
						case AuthenticationSASLContinue(msg):
							var c = new haxe.crypto.Pbkdf2();
							c.init( SHA256 );

							sasl_server_first_message = msg;
							var re = ~/r=([^,]+),s=([^,]+),i=([0-9]+)/;
							re.match(msg);
							var r = re.matched(1);
	
							var sasl_salt = Base64.decode( re.matched(2) );
							var sasl_iterations = Std.parseInt( re.matched(3) );

							var response = 'c=biws,r=${r}';

							sasl_auth_message = '${sasl_client_first_message.substring(3)},$sasl_server_first_message,$response';

							//var salted_password = PBKDF2.deriveKey(params.pass, sasl_salt.toString(), Std.parseInt( sasl_iterations ), 32);
							sasl_salted_password =  c.encode( Bytes.ofString( params.pass ), sasl_salt, sasl_iterations, 32);

							var sasl_client_key = new Hmac(SHA256).make( sasl_salted_password , haxe.io.Bytes.ofString("Client Key", UTF8));
							var sasl_stored_key = Sha256.make(sasl_client_key );
							var sasl_client_signature = new Hmac(SHA256).make(  sasl_stored_key , haxe.io.Bytes.ofString(sasl_auth_message, UTF8));

							var len = sasl_client_key.length;
							var sasl_client_proof =  haxe.io.Bytes.alloc( len );
							for( i in 0 ... len )
								sasl_client_proof.set(i, sasl_client_key.get(i) ^ sasl_client_signature.get(i) );

							writeMessage( SASLResponse( '$response,p=${Base64.encode( sasl_client_proof )}' ) );

						case AuthenticationSASLFinal(msg): 
							var re = ~/v=([^,]+)/;
							re.match(msg);
							var v = re.matched(1);
							
							var server_key = new Hmac(SHA256).make( sasl_salted_password, Bytes.ofString( "Server Key" ) );
							var verifier = new Hmac(SHA256).make( server_key, Bytes.ofString( sasl_auth_message ) ); 

							if( Base64.encode( verifier ) != v )
								throw ('SASL authentication error: Server failed verification');

						case ni: throw ('Unimplemented: $ni');
					}
				}
				case ParameterStatus(args) : status[args.name] = args.value;
				case BackendKeyData(args)  : {
					process_id = args.process_id;
					secret_key = args.secret_key;
				}
				case ReadyForQuery(status) :  break;  // move on when ready
				case Unknown(code): throw ('Unimplemented: $code');
				case ni: throw ('Unimplemented: $ni');
			}
		}

		// connection is now in ready state
	}


    inline static function unexpectedMessage(msg : ServerMessage, state : String) : Void {
        throw 'Unexpected message $msg in $state';
    }

    /**
      This method builds an iteratorfor raw Array<Bytes> from data
      rows on the current socket. In addition to info messages, it expects
      DataRow and CommandComplete responses, and will throw errors if it
      encounters something different.
     **/
    public function getDataRowIterator() : Iterator<Array<Bytes>>{

        return {
            hasNext : function(){
                // RowDescription is necessary because the data row iterator
                // is fast-forwarded at the beginning of the command complete iterator.
                // If RowDescription is showing, it's the start of a normal record set.
                // CommandComplete means that it was a non-record producing query result (e.g. insert).
                // Data row contains useful data, which supports iteration
                switch(current_message){
                    case DataRow(fields)        : return true;
                    case CommandComplete(tag)   : return false;
                    case RowDescription(fields) : return false;
                    case ni                     : unexpectedMessage(current_message, 'getDataRowIterator.hasNext');
                }
                return false;
            },
            next : function(){
                var res : Array<Bytes>;
                switch(current_message){
                    case DataRow(fields) : res = fields;
                    case ni              : unexpectedMessage(current_message, 'getDataRowIterator.next');
                }
                current_message = readMessage();
                return res;
            }
        }
    }

    /**
      This method builds an iterator for command completions.  Multiple
      commands may be present in a single query.
     **/
    public function getCommandCompletesIterator()
        : Iterator<CommandComplete> {
        return {
            hasNext : function(){
                switch(current_message){
                    case ReadyForQuery(status) : return false;
                    default                    : return true;
                }
            },
            next : function(){
                // if there's anything left in the previous row iterator,
                // get rid of it.
                for (r in current_data_iterator) null;

                var res = switch(current_message){
                    case EmptyQueryResponse   : {
                        current_message = readMessage(); // advance the msg
                        EmptyQueryResponse;
                    }
                    case CommandComplete(tag) : {
                        current_message = readMessage(); // advance the msg
                        CommandComplete(tag);
                    }
                    case RowDescription(args) : {
                        current_message = readMessage();
                        current_data_iterator = getDataRowIterator();
                        DataRows(args, current_data_iterator);
                    }
                    case ni : { unexpectedMessage(ni, 'getCommandCompletesIterator.next'); null; }
                }
                return res;
            }
        }
    }

	/**
	  This is the base "request" method from the Connection interface.

      A couple of notes:

      Multiple commands may be present in a postgres query result.  The default
      here is to only use the first one for the ResultSet.  However, this
      library uses an iterator pattern for retrieving data from sockets.
      Since an iterator may be aborted, it is necessary to clean up both
      pre-existing command results, as well as any data rows that the command
      results contain. This is managed by simply exhausting their respective
      iterators.

	 **/
	public function request( query : String ): ResultSet {
        // clean up socket if there are leftovers from a previous request
        for (i in current_complete_iterator) null;

		// write the query
		writeMessage( Query(query) );

        // read the first message
        current_message = readMessage();

		// get the command completions, which will contain results
        current_complete_iterator = this.getCommandCompletesIterator();

        // we only want the first result
        var first_complete = current_complete_iterator.next();

        switch(first_complete){
            case EmptyQueryResponse : return new PostgresResultSet();
            case CommandComplete(tag) : {
                handleTag(tag);
                return new PostgresResultSet();
            }
            case DataRows(row_description, data_iterator) : {
                return new PostgresResultSet(row_description, data_iterator);
            }
        }
	}

	public function handleError(notice){
		throw(notice.message);
		// Further processing is just going to EOF here, why are we doing this?
		while(true){
			switch(socket.readMessage()){
				case ReadyForQuery(status) : break;
				case ni                    : unexpectedMessage(ni, 'handleError');
			}
		}
		throw(notice.message);
	}

	public function close() socket.close();

    /**
      Use postgres escape quote: E'escaped string'
      Note that null values become special NULL tokens.
      Empty strings become NULL in postgres.
     **/
	public function quote( s : String ): String {
        if (s == null) return 'NULL';
        s = s.split("'").join("''").split("\\").join("\\\\");
        return 'E\'$s\'';
	}

	/**
	  Escape a string for a Postgres query.  Note that quote is
	  a safer option.
	 **/
	public function escape( s : String ): String {
		var s = s.split("\n").join("\\n");
		var s = s.split("\r").join("\\r");
		var s = s.split("\t").join("\\t");
		var s = s.split("\\").join("\\\\");
		var s = s.split("'").join("''");
		var s = s.split(String.fromCharCode(12)).join("\\f");
		return s;
	}

	public function addValue( s : StringBuf, v : Dynamic ) : Void {
		if (v == null || Std.isOfType(v,Int)){
			s.add(v);
		} else if (Std.isOfType(v,Bool)){
			s.add(if (cast v) "TRUE" else "FALSE");
		} else {
			s.add(quote(Std.string(v)));
		}
	}

	public function lastInsertId() return this.last_insert_id;
	public function dbName() return "PostgreSQL";
	public function startTransaction() request("BEGIN;");
	public function commit()request("COMMIT;");
	public function rollback() request("ROLLBACK;");

	/**
	  Utility function to create a postgres/md5 authentication string
	 **/
	inline static function md5Auth(o : {pass : String, user : String, salt : String}){
		return "md5" + ((o.pass + o.user).encode() + o.salt).encode();
	}

	/**
	  Utility function that wraps the socket writeMessage function.  Mainly
	  provided for symmetry.
	 **/
	function writeMessage( msg : ClientMessageType){
		socket.writeMessage(msg);
	}

	/**
	  Utility function that wraps the normal socket.readMessage function.
	  This one will filter out and save ParameterStatus messages, which
	  can occur at any time during a Postgres session. It also will throw
	  errors from ErrorResponse messages, and filter out NotificationResponse
	  messages.
	 */
	function readMessage() : ServerMessage {
		while (true){
			switch(socket.readMessage()){
				case ParameterStatus(args) : status[args.name] = args.value;
				case ErrorResponse(notice) : handleError(notice);
				case NoticeResponse(notice) : null; // TODO : do something with this?
				case ni : return ni; // return anything that doesn't match above
			}
		}
	}

	/**
	  Utility function to handle postgres tags (and capture last insert ids)
	 **/
	function handleTag(tag:String){
		var values = tag.split(' ');
		switch(values[0]){
			case "INSERT" : {
			    if (values.length != 3) throw "INSERT command should include oid and row";
				var oid  = Std.parseInt(values[1]);
				var rows = Std.parseInt(values[2]);
				if (rows == 1) this.last_insert_id = oid;
			}
		}
	}
}

class PostgresResultSet implements ResultSet {
	var data_iterator      : Iterator<Array<Bytes>>;
	var field_descriptions : Array<FieldDescription>;

	var cached_rows        : Array<Array<Bytes>>;

	var row_count                  = 0;
	var set_length  : Int    = -1;
	var current_row : Array<Bytes> = null;

	public var length(get, null)  : Int;
	public var nfields(get, null) : Int;

	function get_length(){
	    if (set_length == -1){
            cached_rows   = [for(row in data_iterator) row];
            set_length    = cached_rows.length + row_count;
            data_iterator = cached_rows.iterator();
        }
	    return set_length;
    };

	function get_nfields() return field_descriptions.length;

	public function new(?field_descriptions, ?data_iterator: Iterator<Array<Bytes>>){
	    if (field_descriptions == null) field_descriptions = [];
	    if (data_iterator == null) data_iterator = [].iterator();

		this.data_iterator      = data_iterator;
		this.field_descriptions = field_descriptions;
	}

	public function getFieldsNames(){
		return [for (f in field_descriptions) f.name];
	}

	function getByteResult(col_idx : Int) : Null<Bytes> {
	    if (current_row != null) return current_row[col_idx];
	    else if (data_iterator.hasNext()) {
	        current_row = data_iterator.next();
	        return current_row[col_idx];
        } else return null;

    }
	public function getFloatResult(col_idx: Int) : Float{
	    var bytes = getByteResult(col_idx);
	    if (bytes != null)
            return Std.parseFloat(bytes.toString());
        else
            return 0;
	}

	public function	getIntResult(col_idx: Int) : Int{
	    var bytes = getByteResult(col_idx);
	    if (bytes != null)
            return cast Std.parseInt(bytes.toString());
        else
            return 0;
	}

	public function getResult(col_idx: Int) : String {
	    var bytes = getByteResult(col_idx);
	    if (bytes != null)
            return bytes.toString();
        else
            return null;
	}

	inline public function hasNext(){
	    return data_iterator.hasNext();
    }

	public function next() {
        current_row = data_iterator.next();

		var obj = {};
		for (idx in 0...field_descriptions.length) {
			var field_desc = field_descriptions[idx];
            Reflect.setField( obj,
                    field_desc.name,
                    readType(field_desc.datatype_object_id, current_row[idx])
                    );
		}

		row_count += 1;

		return obj;
	}

	public function	results() return Lambda.list([ for (f in this) f] );

	/**
	  Utility function to parse a postgres timestamp into a Haxe date.
	 **/
	static function parseTimeStampTz(stamp:String){
#if !php
        // php needs the time zone information, and will ignore the millisecond
        // argument.  Other platforms need to have this removed.
		stamp = stamp.split('.')[0];
#end
	    return Date.fromString(stamp);
	}

	/**
	  Utility function that will convert a bytes argument into a Haxe type
	  based on the postgres object id datatype.
	 **/
	static function readType(oid : DataType, bytes : Bytes): Dynamic {
	    if (bytes == null) return null;
		var string = bytes.toString();
		return switch(oid){
			case DataType.oidINT8        : Std.parseInt(string);
			case DataType.oidINT4        : Std.parseInt(string);
			case DataType.oidINT2        : Std.parseInt(string);
			case DataType.oidBOOL        : string=='t';
			case DataType.oidJSON        : haxe.Json.parse(string);
			case DataType.oidFLOAT4      : Std.parseFloat(string);
			case DataType.oidFLOAT8      : Std.parseFloat(string);
			case DataType.oidTIMESTAMPTZ : parseTimeStampTz(string);
			default                      : string;
		}

	}
}

/**
  This enum contains all of the relevant responses for a given command.
  This can result in an empty query response, a command complete tag,
  or a combination of row descriptions, row data, and a complete tag.
 **/
enum CommandComplete {
    EmptyQueryResponse;
    CommandComplete(tag:String);
    DataRows( row_description: Array<FieldDescription>
            , data_rows: Iterator<Array<Bytes>>
            );
}

