module SplitL1Cache ;
	parameter Sets      		    = 2**14; 		// 16k sets
	parameter AddrBits      	    = 32;	 		// 32 Address bits
	parameter DWays      	        = 8;	 		// 8-way Data Cache
	parameter IWays  	            = 4;	 		// 4-way Instruction Cache
	parameter BytesperCacheLines 	= 64;	 		// 64 byte Cache lines
	
	localparam IndexBits 		    = $clog2(Sets); 	                    // Index bits
	localparam ByteOffsetBits 		= $clog2(BytesperCacheLines);		 		// byte select bits
	localparam TagBits 		        = (AddrBits)-(IndexBits+ByteOffsetBits); 	// Tag bits
	localparam DWayselectBits		= $clog2(DWays);			 	// Data way select bits 
	localparam IWayselectBits		= $clog2(IWays);	    // Instruction way select bits

	logic	x;								// Mode select
	logic 	Hit;							// Indicates a Hit or a Miss 
	logic	NotValid;						// Indicates when Invalid line is present
	logic 	[3:0] n;						// Instruction code from Trace file
	logic 	[TagBits - 1 :0] Tag;			// Tag
	logic 	[ByteOffsetBits - 1 :0] Byte;   // Byte select
	logic 	[IndexBits - 1	:0] Index;		// Index
	logic 	[AddrBits - 1 :0] Address;	    // Address
	
	bit 	[DWayselectBits - 1 :0]	Data_ways;		 		// Data ways
	bit 	[IWayselectBits - 1 :0]	Instruction_ways;		// Instruction ways
	bit 	Flag;
	
	int		Trace;					 // file descriptor
	int		TempDisplay;	
	
	int DHitCounter 	= 0; 		 //  Data Cache Hits count
	int DMissCounter 	= 0; 		 //  Data Cache Misses count
	int DReadCounter 	= 0; 		 //  Data Cache read count
	int DWriteCounter 	= 0;		 //  Data Cache write count

	int IHitCounter	    = 0; 			 //  Instruction Cache Hits count
	int IMissCounter 	= 0; 		 //  Instruction Cache Misses count
	int IReadCounter 	= 0; 		 //  Instruction Cache read count
	
	real DHitRatio;					 //  Data Cache Hit ratio
	real IHitRatio; 			     //  Instruction Cache Hit Ratio

	longint CacheIterations = 0;	 //  No.of Cache accesses
	
	// MESI states
	typedef enum logic [1:0]{       				
				Invalid 	= 2'b00,
				Shared 	    = 2'b01, 
				Modified 	= 2'b10, 
				Exclusive 	= 2'b11	
				} MESI;

	// L1 Data Cache			
	typedef struct packed {							
				MESI MESI_bits;
				bit [DWayselectBits-1:0]	LRUbits;
				bit [TagBits	-1:0] 	TagBits;			 
				} DataCache;
DataCache [Sets-1:0] [DWays-1:0] L1DataCache; 

	// L1 Instruction Cache
	typedef struct packed {							
				MESI MESI_bits;
				bit [IWayselectBits-1:0]	LRUbits;
				bit [TagBits	-1:0] 	TagBits;     
				} InstructionCache;
InstructionCache [Sets-1:0][IWays-1:0] L1InstructionCache; 



//  Read instructions from Trace File 

initial	begin
	Cache_Clear();
        Trace = $fopen("traceFile.txt" , "r");
   	if ($test$plusargs("USER_MODE")) 
			x=1;
    	else
    		x=0;
	while (!$feof(Trace))	
	begin
        TempDisplay = $fscanf(Trace, "%h %h\n",n,Address);
        {Tag,Index,Byte} = Address;
    
		case (n) inside
			4'd0:	Data_Read(Tag,Index,x);   		
			4'd1:	DataWritetoL1DataCache (Tag,Index,x);
			4'd2: 	InstructionReadFromL1InstructionCache (Tag,Index,x);
			4'd3:	SendInvalidateCommandFromL2Cache(Tag,Index,x);   
			4'd4:	DataRequestFromL2Cache (Tag,Index,x);
			4'd8:	Cache_Clear();
			4'd9:	DisplayCacheContentsMESIstates();
		endcase			
	end
	$fclose(Trace);
	DHitRatio = (real'(DHitCounter)/(real'(DHitCounter) + real'(DMissCounter))) * 100.00;
	IHitRatio 	= (real'(IHitCounter) /(real'(IHitCounter)  + real'(IMissCounter))) *100.00;

	$display("---------Statistics for Data Cache-------------");
	$display("Data Cache Reads= %d\n Data Cache Writes= %d\n Data Cache Hits= %d \n Data Cache Misses= %d \n Data Cache Hit Ratio = %f\n", DReadCounter, DWriteCounter, DHitCounter, DMissCounter, DHitRatio);
	
	$display("---------Instruction Cache Statistics----------");
	$display("Instruction Cache Reads = %d \nInstruction Cache Misses = %d \nInstruction Cache Hits = %d \nInstruction Cache Hit Ratio =  %f \n",IReadCounter, IMissCounter, IHitCounter, IHitRatio);
	$finish;													
end

//Updating LRU Bits



task automatic UpdateLRUBits_ins(logic [IndexBits-1:0]iIndex, ref bit [IWayselectBits-1:0] Instruction_ways ); // Update LRU bits in INSTRUCTION CACHE
	logic [IWayselectBits-1:0]temp;
	temp = L1InstructionCache[iIndex][Instruction_ways].LRUbits;
	
	for (int j = 0; j < IWays ; j++)
		L1InstructionCache[iIndex][j].LRUbits = (L1InstructionCache[iIndex][j].LRUbits > temp) ? L1InstructionCache[iIndex][j].LRUbits - 1'b1 : L1InstructionCache[iIndex][j].LRUbits;
	
	L1InstructionCache[iIndex][Instruction_ways].LRUbits = '1;
endtask 


// Write Data to L1 Data Cache


task DataWritetoL1DataCache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic x);
	
	DWriteCounter++ ;
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	
	if (Hit == 1)
	begin
		DHitCounter++ ;
		UpdateLRUBits_data(Index, Data_ways );	
		if (L1DataCache[Index][Data_ways].MESI_bits == Shared)
		begin
			L1DataCache[Index][Data_ways].MESI_bits = Exclusive;
			if(x==1) $display("Write to L2 address %d'h%h" ,AddrBits,Address);
		end
		else if(L1DataCache[Index][Data_ways].MESI_bits == Exclusive)
			L1DataCache[Index][Data_ways].MESI_bits = Modified;
	end
	else
	begin
		DMissCounter++ ;
		If_Invalid_Data(Index , NotValid , Data_ways );
	
		if (NotValid)
		begin
			Data_Allocate_CacheLine(Index,Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1DataCache[Index][Data_ways].MESI_bits = Exclusive;
			if (x==1)
				$display("Read for ownership from L2 %d'h%h\nWrite to L2 address %d'h%h ",AddrBits,Address,AddrBits,Address);
		end
		else
		begin
			Eviction_DATA(Index, Data_ways);
			Data_Allocate_CacheLine(Index, Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1DataCache[Index][Data_ways].MESI_bits = Modified;  
			if (x==1) 
				$display("Read for ownership from L2 %d'h%h",AddrBits,Address);
		end
	end	
endtask



//Read Data From L1 Cache


task Data_Read ( logic [TagBits-1 :0] Tag, logic [IndexBits-1:0] Index, logic x); 
	
	DReadCounter++ ;
	Data_Address_Valid (Index,Tag,Hit,Data_ways);
	
	if (Hit == 1)
	begin
		DHitCounter++ ;
		UpdateLRUBits_data(Index, Data_ways );
		L1DataCache[Index][Data_ways].MESI_bits = (L1DataCache[Index][Data_ways].MESI_bits == Exclusive) ? Shared : L1DataCache[Index][Data_ways].MESI_bits ;		
	end
	else
	begin
		DMissCounter++ ;
		NotValid = 0;
		If_Invalid_Data (Index , NotValid , Data_ways );
		
		if (NotValid)
		begin
			Data_Allocate_CacheLine(Index,Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1DataCache[Index][Data_ways].MESI_bits = Exclusive;   
			
			if (x==1)
				$display("Read from L2 address %d'h%h" ,AddrBits,Address);
		end
		else    
		begin
			Eviction_DATA(Index, Data_ways);
			Data_Allocate_CacheLine(Index, Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1DataCache[Index][Data_ways].MESI_bits = Exclusive;  
			
			if (x==1)
				$display("Read from L2 address %d'h%h" ,AddrBits,Address);
		end
	end	
endtask


//Instruction Fetch

task InstructionReadFromL1InstructionCache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic x);
	
	IReadCounter++ ;
	INSTRUCTION_Address_Valid (Index, Tag, Hit, Instruction_ways);
	
	if (Hit == 1)
	begin
		IHitCounter++ ;
		UpdateLRUBits_ins(Index, Instruction_ways );
		L1InstructionCache[Index][Instruction_ways].MESI_bits = (L1InstructionCache[Index][Instruction_ways].MESI_bits == Exclusive) ? Shared : L1InstructionCache[Index][Instruction_ways].MESI_bits	;
	end
	else
	begin
		IMissCounter++ ;
		If_Invalid_INSTRUCTION(Index ,  NotValid , Instruction_ways );
		
		if (NotValid)
		begin
			INSTRUCTION_Allocate_Line(Index,Tag, Instruction_ways);
			UpdateLRUBits_ins(Index, Instruction_ways );
			L1InstructionCache[Index][Instruction_ways].MESI_bits = Exclusive; 
			if (x==1)
				$display("Read from L2 address %d'h%h" ,AddrBits,Address);
		end
		else
		begin
			Eviction_INSTRUCTION(Index, Instruction_ways);
			INSTRUCTION_Allocate_Line(Index, Tag, Instruction_ways);
			UpdateLRUBits_ins(Index,  Instruction_ways );
			L1InstructionCache[Index][Instruction_ways].MESI_bits = Exclusive;         
			if (x==1)
				$display("Read from L2 address %d'h%h" ,AddrBits,Address);
		end
	end
endtask


//Data Request From L2 Cache

task DataRequestFromL2Cache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic x); // Data Request from L2 Cache
	
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	if (Hit == 1)
		case (L1DataCache[Index][Data_ways].MESI_bits) inside
		
			Exclusive:	L1DataCache[Index][Data_ways].MESI_bits = Shared;
			Modified :	begin
						L1DataCache[Index][Data_ways].MESI_bits = Invalid;
						if (x==1)
							$display("Return data to L2 address %d'h%h" ,AddrBits,Address);
					end
		endcase
endtask   


//Address Valid task

task automatic Data_Address_Valid (logic [IndexBits-1 :0] iIndex, logic [TagBits -1 :0] iTag, output logic Hit , ref bit [DWayselectBits-1:0] Data_ways ); 
	Hit = 0;

	for (int j = 0;  j < DWays ; j++)
		if (L1DataCache[iIndex][j].MESI_bits != Invalid) 	
			if (L1DataCache[iIndex][j].TagBits == iTag)
			begin 
				Data_ways = j;
				Hit = 1; 
				return;
			end			
endtask

task automatic INSTRUCTION_Address_Valid (logic [IndexBits-1 :0] iIndex, logic [TagBits -1 :0] iTag, output logic Hit , ref bit [IWayselectBits-1:0] Instruction_ways);
	Hit = 0;

	for (int j = 0;  j < IWays ; j++)
		if (L1InstructionCache[iIndex][j].MESI_bits != Invalid) 
			if (L1InstructionCache[iIndex][j].TagBits == iTag)
			begin 
				Instruction_ways = j;
				Hit = 1; 
				return;
			end
endtask

//Check for Invalid states

task automatic If_Invalid_Data (logic [IndexBits-1:0] iIndex, output logic NotValid, ref bit [DWayselectBits-1:0] Data_ways); // Find Invalid Cache line in DATA CACHE
	NotValid =  0;
	for (int i =0; i< DWays; i++ )
	begin
		if (L1DataCache[iIndex][i].MESI_bits == Invalid)
		begin
			Data_ways = i;
			NotValid = 1;
			return;
		end
	end
endtask

task automatic If_Invalid_INSTRUCTION (logic [IndexBits - 1:0] iIndex, output logic NotValid, ref bit [IWayselectBits-1:0] Instruction_ways); // Find Invalid Cache line in DATA CACHE
	NotValid =  0;
	for(int i =0; i< IWays; i++ )
		if (L1InstructionCache[iIndex][i].MESI_bits == Invalid)
		begin
			Instruction_ways = i;
			NotValid = 1;
			return;
		end
endtask

//Send Invalidate Command From L2 Cache

task SendInvalidateCommandFromL2Cache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic x);
	
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	if (Hit == 1)
	begin
	 	if( x==1 && (L1DataCache[Index][Data_ways].MESI_bits == Modified)) 
			$display("Write to L2 address        %d'h%h" ,AddrBits,Address);
		L1DataCache[Index][Data_ways].MESI_bits = Invalid;
	end
endtask

//Cache line Allocation

task automatic Data_Allocate_CacheLine (logic [IndexBits -1:0] iIndex, logic [TagBits -1 :0] iTag, ref bit [DWayselectBits-1:0] Data_ways); // Allocacte Cache Line in DATA CACHE
	L1DataCache[iIndex][Data_ways].TagBits = iTag;
	UpdateLRUBits_data(iIndex, Data_ways);		
endtask

task automatic INSTRUCTION_Allocate_Line (logic [IndexBits -1 :0] iIndex, logic [TagBits -1 :0] iTag, ref bit [IWayselectBits-1:0] Instruction_ways); // Allocacte Cache Line in INSTRUCTION CACHE
	L1InstructionCache[iIndex][Instruction_ways].TagBits = iTag;
	UpdateLRUBits_ins(iIndex, Instruction_ways);
endtask

//Eviction Line task

task automatic Eviction_DATA (logic [IndexBits -1:0] iIndex, ref bit [DWayselectBits-1:0] Data_ways);
	for (int i =0; i< DWays; i++ )
		if( L1DataCache[iIndex][i].LRUbits ==  '0 )
		begin
			if( x==1 && (L1DataCache[iIndex][i].MESI_bits == Modified) )
				$display("Write to L2 address %d'h%h" ,AddrBits,Address);
			Data_ways = i;
		end
endtask

task automatic Eviction_INSTRUCTION (logic [IndexBits - 1:0] iIndex, ref bit [IWayselectBits-1:0] Instruction_ways);
	for (int i =0; i< IWays; i++ )
		if( L1InstructionCache[iIndex][i].LRUbits == '0 )
		begin
			if( x==1 && (L1InstructionCache[iIndex][i].MESI_bits == Modified) )
					$display("Write to L2 address %d'h%h" ,AddrBits,Address);				
			Instruction_ways = i;
		end
endtask


//To Print Cache contents and MESI States

task DisplayCacheContentsMESIstates();		
	$display("***DATA CACHE CONTENTS AND MESI states***");
	
	for(int i=0; i< Sets; i++)
	begin
		for(int j=0; j< DWays; j++) 
			if(L1DataCache[i][j].MESI_bits != Invalid)
			begin
				if(!Flag)
				begin
					$display("Index = %d'h%h\n", IndexBits , i );
					Flag = 1;
				end
				$display(" Way = %d \n Tag = %d'h%h \n MESI = %s \n LRU = %d'b%b", j,TagBits,L1DataCache[i][j].TagBits, L1DataCache[i][j].MESI_bits,DWayselectBits,L1DataCache[i][j].LRUbits);
			end
		Flag = 0;
	end
	$display("----------END OF DATA CACHE-----------\n\n");
	$display("***INSTRUCTION CACHE CONTENTS AND MESI states***");
	for(int i=0; i< Sets; i++)
	begin
		for(int j=0; j< IWays; j++) 
			if(L1InstructionCache[i][j].MESI_bits != Invalid)
			begin
				if(!Flag)
				begin
					$display("Index = %d'h%h\n",IndexBits,i);
					Flag = 1;
				end
				$display(" Way = %d \n Tag = %d'h%h \n MESI = %s \n LRU = %d'b%b", j,TagBits, L1InstructionCache[i][j].TagBits, L1InstructionCache[i][j].MESI_bits,IWayselectBits,L1InstructionCache[i][j].LRUbits);
			end
		Flag = 0;
	end
	$display("-----END OF INSTRUCTION CACHE-----\n\n");
endtask

//Clear cache

task Cache_Clear();
DHitCounter 	= 0;
DMissCounter 	= 0;
DReadCounter 	= 0;
DWriteCounter   = 0;
IHitCounter  	= 0;
IMissCounter 	= 0;
IReadCounter 	= 0;
fork
for(int i=0; i< Sets; i++) 
		for(int j=0; j< DWays; j++) 
			L1DataCache[i][j].MESI_bits = Invalid;

	for(int i=0; i< Sets; i++) 
		for(int j=0; j< IWays; j++) 
			L1InstructionCache[i][j].MESI_bits = Invalid;
join
endtask
endmodule
