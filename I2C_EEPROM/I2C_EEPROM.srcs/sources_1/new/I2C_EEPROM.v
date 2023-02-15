`timescale 1ns / 1ps



module I2C_EEPROM(
    input wire clk,
    input wire rst,

    input   wire            write_req  ,
    input   wire            read_req  ,
    input   wire            start   ,
    input   wire    [7:0]   dev_addr, //will soon be loaded into master_data
    input   wire    [7:0]   mem_addr, //will soon be loaded into master_data
    input   wire    [7:0]   write_data , //will soon be loaded into master_data

    output  reg     [7:0]   read_data , //the content of master_data(after reading) will soon be loaded into this variable, so that we can output it to the top controller
    output  reg            read_done ,
    output  reg            write_done,
    output reg scl, 
    
    inout wire sda
    ); 
// WORKING STATE OF THE I2C driver
parameter IDLE = 10'b00_0000_0001;
parameter WR_START= 10'b00_0000_0010;
parameter WR_DEV = 10'b00_0000_0100;
parameter WR_MEM = 10'b00_0000_1000;
parameter WR_DATA = 10'b00_0001_0000;
parameter RD_START= 10'b00_0010_0000;
parameter RD_DEV = 10'b00_0100_0000;
parameter RD_DATA = 10'b00_1000_0000;
parameter STOP = 10'b01_0000_0000;
parameter ERROR = 10'b10_0000_0000;
//
//system clk, the I2C clk and some other definitions
parameter SYS_CYCLE = 20;// 50M
parameter I2C_CYCLE = 5000;//I2C 200K
parameter counter_MAX = (I2C_CYCLE/SYS_CYCLE) -1;//the maximum value of counter
parameter T_HIGH = 2000 ;//I2C clk HIGH duration
parameter T_LOW = 3000 ;//I2C  clk LOW duration
parameter FLAG0 = ((T_HIGH/SYS_CYCLE)>>1) - 1;//SCL the middle of HIGH duration
parameter FLAG1 = (T_HIGH/SYS_CYCLE) - 1;//SCL fallng edge
parameter FLAG2 = (T_HIGH/SYS_CYCLE) + ((T_LOW/SYS_CYCLE)>>1) -1; // the middle of LOW duration
parameter FLAG3 = (T_HIGH/SYS_CYCLE) + (T_LOW/SYS_CYCLE) - 1;//SCL rising edge

reg [9:0] state = IDLE; //the working state of the I2C driver
reg ACK;
reg enable_wr_driver;
reg sda_driver;
wire sda_receive;// when driver should't write(enable_wr_driver=0), in read mode for example, this line is used to receive data from the slave.

// sda is the value of the sda line of the driver, if driver is now in the write mode(enable_wr_driver=1).
assign sda = enable_wr_driver ? sda_driver : 1'bz; 
assign sda_receive = sda; //High impedance when not used


reg WORKING_FLAG; // Is the driver is working?

always@ (posedge clk) begin
    if(rst == 1'b1) begin
        WORKING_FLAG <= 'd0;
    end
    else if(state == WR_START) begin //The driver started to work upon transition into state WR_START
        WORKING_FLAG <= 'd1;
    end
    else if(write_done || read_done) begin //Finish reading or writing, the module turn off. 
        WORKING_FLAG <= 'd0;
    end
    else begin
        WORKING_FLAG <= WORKING_FLAG;
    end
end

reg [12:0] counter;
always@ (posedge clk) begin
    if(rst == 'd1) begin
        counter <= 'd0;
    end
    else if(WORKING_FLAG == 'd1) begin
        if(counter == counter_MAX) begin
            counter <= 'd0;
        end
        else begin
            counter <= counter + 1;
        end
    end
    else begin
        counter <= 'd0;
    end
end


reg driver_clk; //it has only 20ns HIGH duration, one SCL cycle has four driver_clk cycle
always@ (posedge clk) begin
    if(rst == 1'b1) begin
        driver_clk <= 'd0;
    end
    else if(WORKING_FLAG == 'd1) begin
        if((counter == FLAG0) || (counter == FLAG1) || (counter == FLAG2) || (counter == FLAG3)) begin
            driver_clk <= 'd1;
        end
        else begin
            driver_clk <= 'd0;
        end
    end
    else begin
        driver_clk <= 'd0; 
    end
end

always@ (posedge clk) begin
    if(rst == 'd1) begin
        scl <= 'd1;
    end
    else if(WORKING_FLAG == 'd1) begin
        if((counter >= FLAG1) && (counter <= FLAG3)) begin //***
            scl <= 'd0;
        end
        else begin
            scl <= 'd1;
        end
    end    
    else begin
        scl <= 'd1;
    end
end

reg [4:0] driver_counter; //Used to count how many cycle of driver clk
wire end_of_driver_counter;
reg driver_limit;
assign end_of_driver_counter = (driver_counter == driver_limit);

always@ (posedge clk) begin
    if(rst == 'd1) begin
        driver_counter <= 'd0;    
    end
    else if(WORKING_FLAG == 'd0) begin
        driver_counter <= 'd0;
    end
    else if(driver_clk) begin
        if(end_of_driver_counter) begin
            driver_counter <= 'd0;        
        end
        else begin 
            driver_counter <= driver_counter + 1;
        end
    end
    else begin
        driver_counter <= driver_counter;
    end
end

//define driver limit as the limit of driver_counter of a certain state

always@ (*) begin

    case(state)
        WR_START: driver_limit = 7-1;
        WR_DEV,WR_MEM,WR_DATA,RD_DEV,RD_DATA: driver_limit = 36 - 1;
        RD_START: driver_limit= 4 - 1;
        STOP: driver_limit = 4 - 1;
        
        default: driver_limit = 0;
    endcase
end

//state
wire master_mode; //read or write
always@ (posedge clk) begin
    if(rst == 'd1) begin
        state <= IDLE;
    end
    else begin
    
        case(state) 
            IDLE: begin
                if(start == 'd1 && (write_req || read_req)) begin
                    state <= WR_START;
                end
                else begin
                    state <= state;
                end
            end
            
            WR_START: if(end_of_driver_counter && driver_clk) begin
                        state <= WR_DEV;
                     end
                     else begin
                        state <= state;
                     end
            WR_DEV: if(end_of_driver_counter && driver_clk && ACK == 1'b1) begin
                        state <= WR_MEM;
                     end
                     else begin
                        state <= state;
                     end
            WR_MEM: if(end_of_driver_counter && driver_clk && ACK == 1'b1) begin
                        if(write_req == 1'b1) begin
                            state <= WR_DATA;
                        end
                        else begin
                            state <= RD_START;
                        end
                    end
                    else begin
                       state <= state;
                    end
                    
            WR_DATA:  if(end_of_driver_counter && driver_clk && ACK == 1'b1) begin
                        state <= STOP;
                     end
                     else begin
                        state <= state;
                     end
    
            RD_START:if(end_of_driver_counter && driver_clk && read_req) begin
                        state <= RD_DEV;
                     end
                     else begin
                        state <= state;
                     end
            
            RD_DEV: if(end_of_driver_counter && driver_clk && ACK == 1'b1) begin
                        state <= RD_DATA;
                    end
                    else begin
                       state <= state;
                    end
            
            RD_DATA: if(end_of_driver_counter && driver_clk && ACK == 1'b1) begin
                        state <= STOP;
                     end
                     else begin
                        state <= state;
                     end
            
             STOP:  if(end_of_driver_counter && driver_clk) begin
                       state <= IDLE;
                    end
                    else begin
                       state <= state;
                    end
             
            default: state <= IDLE;
        endcase
    end
end

//enable_wr_driver
always@ (posedge clk) begin
    if(rst == 'd1) begin
        enable_wr_driver <= 1'b0;
    end
    else if((state == WR_START) || (state == RD_START) || (state == STOP)) begin
        enable_wr_driver <= 1'b1;
    end
    else if((state==WR_DEV) || (state==WR_MEM) || (state==WR_DATA) || (state==RD_DEV)) begin
        if(driver_counter < 'd32) begin
            enable_wr_driver <= 1'b1; // master transmitting data
        end
        else begin
            enable_wr_driver <= 1'b0; //slave response "ACK"
        end
    end
    else if(state == RD_DATA) begin
        if(driver_counter < 'd32) begin
            enable_wr_driver <= 1'b0; // slave transmitting data
        end
        else begin
            enable_wr_driver <= 1'b1; // master response ACK or NACK 
        end
    end
    else begin
        enable_wr_driver <= 1'b0;
    end
end

//sda_driver
reg [7:0] master_data; //deal with every type of data including dev_addt, mem_addr, write/read data
always@ (posedge clk) begin
    if(rst == 'd1) begin
        sda_driver <= 1'b1;
    end
    else begin
        case(state)
            WR_START: begin
                if(driver_counter == 'd4 && driver_clk) begin
                    sda_driver <= 1'b0; //Generating a falling edge indicates START 
                end
                else begin
                    sda_driver <= sda_driver;
                end
            end
           
            WR_DEV,WR_MEM,WR_DATA,RD_DEV:begin
                sda_driver <= master_data[7]; //load the most significant bit first
            end
            
            RD_START: begin
                if(driver_counter == 'd0) begin
                    sda_driver <= 'd1;               
                end
                else if(driver_counter == 'd1 && driver_clk) begin
                    sda_driver <= 'd0;
                end
            end
            
            RD_DATA: begin
                if(driver_counter >= 'd32) begin //We can modify this part if we want to read more bytes in a RD_DATA
                    sda_driver <= 'd1; //Master(driver) generate a NACK signal to indicate the end of reading EEPROM
                end
                else begin
                    sda_driver <= sda_driver;
                end
            end
            
            STOP: begin
                if(driver_counter == 'd0) begin
                    sda_driver <= 'd0;
                end
                else if(driver_counter == 'd1 && driver_clk) begin
                    sda_driver <= 'd1; //Master generate a rising edge to indicate the stop of operation
                end
            end
            
            default: sda_driver <= sda_driver;
            
        endcase
    end
    
end


//ACK
always @(posedge clk)begin
    if(rst == 1'b1)begin
    	ACK <= 1'b0;
    end
    else begin
    	case(state)
    		WR_DEV:begin
    			if(driver_counter>='d32 && driver_counter[1:0]=='d1 && driver_clk && sda==1'b0)
    				ACK <= 1'b1;
    			else if(end_of_driver_counter)
    				ACK <= 1'b0;
    		    else begin
    		        ACK <= ACK;
    		    end
    		end

    		WR_MEM:begin
    			if(driver_counter>='d32 && driver_counter[1:0]=='d1 && driver_clk && sda==1'b0)
    				ACK <= 1'b1;
    			else if(end_of_driver_counter)  //Æ[¹îÂI
    				ACK <= 1'b0;
    			else begin
    		        ACK <= ACK;
    		    end
    		end

    		WR_DATA:begin
    			if(driver_counter>='d32 && driver_counter[1:0]=='d1 && driver_clk && sda==1'b0)
    				ACK <= 1'b1;
    			else if(end_of_driver_counter)
    				ACK <= 1'b0;
     		    else begin
    		        ACK <= ACK;
    		    end   				
    		end

    		RD_DEV:begin
    			if(driver_counter>='d32 && driver_counter[1:0]=='d1 && driver_clk && sda==1'b0)
    				ACK <= 1'b1;
    			else if(end_of_driver_counter)
    				ACK <= 1'b0;
     		    else begin
    		        ACK <= ACK;
    		    end   				
    		end

    		RD_DATA:begin
    			if(driver_counter>='d32 && driver_counter[1:0]=='d1 && driver_clk && sda==1'b1) //when master sends NACK, raise the flag ACK
    				ACK <= 1'b1;
    			else if(end_of_driver_counter)
    				ACK <= 1'b0;
     		    else begin
    		        ACK <= ACK;
    		    end   				
    		end

    		default: ACK <= 1'b0;
    	endcase
    end
end

//--------------------master_data--------------------
always @(posedge clk)begin
    if(rst == 1'b1)begin
        master_data <= 'd0;
    end
    else begin
        case(state)
            IDLE:begin
                master_data <= 'd0;
            end

            WR_START:begin
                master_data <= {dev_addr[7:1],1'b0}; //the LSB bit is the control bit indicate "write"
            end

            WR_DEV:begin
                if(end_of_driver_counter && ACK==1'b1) //If there is such a device(ACK), then push memory address into master_data
                    master_data <= mem_addr;
                else if(driver_counter<'d32 && driver_counter[1:0]==2'd3 && driver_clk) 
                    master_data <= master_data << 1; //every 4 cycles of driver_clk, left shift the master_data to change the MSB bit
                else begin
                    master_data <= master_data;
                end
            end

            WR_MEM:begin
                if(end_of_driver_counter && ACK==1'b1 && write_req==1'b1)
                     master_data <= write_data;
                else if(driver_counter<'d32 && driver_counter[1:0]==2'd3 && driver_clk)
                     master_data <= master_data << 1;
                else begin
                     master_data <= master_data;
                end
            end

            WR_DATA:begin
                if(driver_counter<'d32 && driver_counter[1:0]==2'd3 && driver_clk)
                     master_data <= master_data << 1;
                else
                     master_data <= master_data; 
            end

            RD_START:begin
                master_data <=  {dev_addr[7:1],1'b1};
            end

            RD_DEV:begin
                if(end_of_driver_counter && ACK==1'b1)
                    master_data <= 'd0; //after designating the device, make master_data empty becaiuse we are going to "read" mode
                else if(driver_counter<'d32 && driver_counter[1:0]==2'd3 && driver_clk)
                    master_data <= {master_data[6:0],1'b0};
                else begin
                     master_data <= master_data;
                end                    
            end

            RD_DATA:begin
                if(driver_counter<'d32 && driver_counter[1:0]==2'd1 && driver_clk)
                    master_data <= {master_data[6:0],sda_receive}; //read the MSB first, that's we put the received data in the very back(LSB)
                else
                    master_data <= master_data;
            end

            default:begin
                master_data <= master_data;
            end
        endcase
    end
end

//read_data
always@ (posedge clk) begin
    if(rst == 'd1) begin
        read_data <= 'd0;
    end
    else if(read_done) begin
        read_data <= master_data;
    end
    else begin
        read_data <= read_data;
    end
end

//--------------------write_done,read_done--------------------
always @(posedge clk)begin
    if(rst == 1'b1)begin
        write_done <= 1'b0;
        read_done <= 1'b0;
    end
    else if(state == STOP && end_of_driver_counter) begin
        if(write_req==1'b1) begin
            write_done <= 1'b1;
            read_done <= read_done;
        end
        else begin
            write_done <= write_done;
            read_done <= 1'b1;
        end
    end
    else begin
        write_done <= 1'b0;
        read_done <= 1'b0;
    end
end


endmodule
