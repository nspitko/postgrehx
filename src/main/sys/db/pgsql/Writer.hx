package sys.db.pgsql;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.zip.Writer;
using sys.db.pgsql.ByteTools;

class Writer {
	var bb : BytesBuffer;
	var length_marker : Int;
	var pos : Int;

	public function new(){
		bb = new BytesBuffer();
		length_marker = -1;
		pos = 0;
	}

	public function addInt32(number: Int){
		// @todo this looks... kinda insane?
		// I assume this is correcting to javascript bullshit??
		// Disabling it for now
/*
		var unsigned = (number < 0) ? (number + 0xffffff) : number;
		bb.addByte(Math.floor(unsigned / 0xffffff));
		unsigned &= 0xffffff;
		bb.addByte(Math.floor(unsigned / 0xffff));
		unsigned &= 0xffff;
		bb.addByte(Math.floor(unsigned / 0xff));
		unsigned &= 0xff;
		bb.addByte(Math.floor(unsigned));
		*/

		bb.addByte((number >> 24) & 0xFF);
		bb.addByte((number >> 16) & 0xFF);
		bb.addByte((number >> 8) & 0xFF);
		bb.addByte(number & 0xFF);
		pos += 4;
		return this;
	}

	public function addInt16(number: Int){
		var unsigned = (number < 0) ? (number + 0xffffff) : number;
		bb.addByte(Math.floor(unsigned / 0xff));
		unsigned &= 0xff;
		bb.addByte(Math.floor(unsigned));
		pos += 2;
		return this;
	}
	public function msgLength(){
		length_marker = pos;
		this.addInt32(0);
		pos+=4;
		return this;
	}

	public function addString(str: String){
		var b = Bytes.ofString(str);
		bb.addBytes(b, 0, b.length);
		pos += b.length;
		return this;
	}

	/**
	  null delimited string
	 **/
	public function addCString(str: String){
		var b = Bytes.ofString(str);
		bb.addBytes(b, 0, b.length);
		bb.addByte(0);
		pos += b.length + 1;
		return this;
	}

	public function addMultiCString(strs: Array<String>){
		for (s in strs) this.addCString(s);	
		bb.addByte(0);
		pos += 1;
		return this;
	}

	public function addObj(obj:Dynamic){
		for (k in Reflect.fields(obj)) {
			this.addCString(k);
			this.addCString(Reflect.field(obj, k));
		}
		this.addByte(0x00); // delimit hash
		pos += 1;
		return this;
	}
	public function addByte(byte:Int){
		bb.addByte(byte);
		pos += 1;
		return this;
	}
	public function addBytes(src:Bytes, pos:Int, len:Int){
		bb.addBytes(src, pos, len);
		this.pos += len;
		return this;
	}

	public function getBytes():Bytes{
		if (length_marker != -1)
		{
			var len = bb.length - length_marker;
			@:privateAccess
			{
				// This is a gross hack, should just add a proper "setInt32" big endian func
				var oldPos = bb.pos;
				bb.pos = length_marker;
				addInt32(len);
				bb.pos = oldPos;
			}
			
		}

		var bytes = bb.getBytes();
		//if (length_marker != -1){
		//	bytes.setInt32(length_marker, bytes.length - length_marker);
		//}
		return bytes;
		
	}
}

