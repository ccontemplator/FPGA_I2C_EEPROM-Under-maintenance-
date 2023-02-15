`timescale 1ns / 1ps


module top_controller(
    input   wire clk ,
    input   wire rst_n ,
    output  wire scl ,
    inout   wire sda
    );

parameter   IDLE = 3'b000;
parameter   CONFIG = 3'b001;
parameter   WRITE = 3'b010;
parameter   PROC = 3'b011;
parameter   READ = 3'b100;
parameter   MEM_ADDR_MAX = 'd31;

parameter   SYS_CYCLE = 20; //50MHz
parameter   CONFIG_MAX_TIME = 20000000; //20ms configuration time to ready
parameter   CONFIG_MAX_CYCLE = CONFIG_MAX_TIME/SYS_CYCLE - 1; 

wire rst;
assign rst = ~rst_n;

reg [2:0] state; //the state of the top controller
reg ready;
reg mode;

wire read_done; //output from the driver
wire write_done; //output from the driver
reg read_req; //input to the driver
reg write_req; //input to the driver
reg start; //input to the driver

wire [7:0] dev_addr; //input to the driver
reg [7:0] write_data;
reg [7:0] mem_addr; //input to the driver
assign dev_addr = 8'b1010_0000; //or 8'ha0, the 7-bit device address of EEPROM is 1010_000

wire [7:0] read_data;

//state
always @(posedge clk)begin
    if(rst == 1'b1)begin
        state <= IDLE;
    end
    else begin
        case(state)
            IDLE:begin
                 state <= CONFIG;
            end

            CONFIG:begin 
                if(mode==1'b0 && ready)
                    state <= WRITE;
                else if(mode==1'b1 && ready)
                    state <= READ;
                else begin
                    state <= state;
                end
            end

            WRITE:begin
                if(write_done)
                    state <= IDLE; //*** CONFIG?
                else if(mode==1'b1) //go into read mode
                    state <= CONFIG;
                else
                    state <= WRITE;
            end
            
            READ:begin
                if(read_done)
                    state <= IDLE;
                else
                    state <= READ;
            end

            default:begin
                state <= IDLE;
            end
        endcase
    end
end

//define the time required to be ready    
reg [24:0] config_counter;
always@ (posedge clk) begin
    if(rst == 'd1) begin
        config_counter <= 'd0; //IDLE state
    end
    else if(state == CONFIG) begin
        if(config_counter == CONFIG_MAX_CYCLE) begin
            config_counter <= 'd0;
        end
        else begin
            config_counter <= config_counter + 1'b1;
        end
    end
    else begin
        config_counter <= 'd0;
    end
end

always@ (posedge clk) begin
    if(rst == 'd1) begin
        ready <= 'd0;
    end
    else if(config_counter == CONFIG_MAX_CYCLE) begin
        ready <= 'd1;
    end
    else if(start == 'd1) begin
        ready <= 'd0;
    end
    else begin
        ready <= ready;
    end
end
    
//start       The "start" value will determine whether the driver will transit into WR_START from IDLE or not. Note that the driver is by default in IDLE before receiving start.
always @(posedge clk)begin
    if(rst == 1'b1)begin
        start <= 1'b0;
    end
    else if((state == CONFIG) && (mode == 1'b0) && ready && (mem_addr == MEM_ADDR_MAX))begin 
        start <= 1'b1; //when satisfying these conditions, top controller send a "start" to driver, the driver thereafter will switch to WR_START
    end
    else if((state == CONFIG) && (mode == 1'b0) && ready && (mem_addr == MEM_ADDR_MAX))begin
        start <= 1'b1; //when satisfying these conditions, top controller send a "start" to driver, the driver thereafter will switch to RD_START
    end
    else begin
    	start <= 1'b0;
    end
end   

//mode
always @(posedge clk) begin
    if(rst == 1'b1)begin
        mode <= 1'b0;
    end
    else if(mem_addr == MEM_ADDR_MAX) begin //Upon writing or reading limit, the top controller will turn to opposite mode (say, write -> read)
        mode <= ~mode; 
    end
    else begin
        mode <= mode;
    end 
end

//write_req
always @(posedge clk) begin
    if(rst == 1'b1)begin
        write_req <= 1'b0;
    end
    else if(write_done) begin
        write_req <= 1'b0;
    end
    else if(state == CONFIG && mode == 'd0 && ready && mem_addr != MEM_ADDR_MAX) begin //when the top controller is ready to write and the mem_addr is not at the limt
        write_req <= 'd1; 
    end
    else begin
        write_req <= write_req;
    end 
end

//read_req
always @(posedge clk) begin
    if(rst == 1'b1)begin
        read_req <= 1'b0;
    end
    else if(read_done) begin
        read_req <= 1'b0;
    end
    else if(state == CONFIG && mode == 'd1 && ready && mem_addr != MEM_ADDR_MAX) begin //when the top controller is ready to read and the mem_addr is not at the limt
        read_req <= 'd1; 
    end
    else begin
        read_req <= read_req;
    end 
end

//creating periodic mem_addr & write_data, we set the two to be the same now.
always @(posedge clk) begin
    if(rst == 1'b1) begin
        mem_addr <= 'd0;
        write_data <= 'd0;
    end
    else if((mode == 'd0 && write_done == 'd1) || (mode == 'd1 && read_done == 'd1)) begin
        if(mem_addr == MEM_ADDR_MAX) begin
            mem_addr <= 'd0;
            write_data <= 'd0;
        end 
        else begin
            mem_addr <= mem_addr + 'd1;
            write_data <= write_data + 'd1;
        end 
    end
    else begin
        mem_addr <= mem_addr;
        write_data <= write_data;
    end
end

I2C_EEPROM I2C_driver_obj (
		.clk      (clk), 
		.rst      (rst), 
		.write_req   (write_req),
		.read_req   (read_req),
		.start    (start),	
		.dev_addr (dev_addr),
		.mem_addr (mem_addr),
		.write_data  (write_data),
		.read_data  (read_data),	
		.read_done  (read_done),
		.write_done  (write_done),			
		.scl      (scl), 
		.sda      (sda)
);
    
endmodule
