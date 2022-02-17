// Copyright 2017 Embecosm Limited <www.embecosm.com>
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// System bus for core-v-mini-mcu
// Contributor: Jeremy Bennett <jeremy.bennett@embecosm.com>
//              Robert Balas <balasr@student.ethz.ch>
//              Davide Schiavone <davide@openhwgroup.org>


module system_bus
  import obi_pkg::*;
  import addr_map_rule_pkg::*;
#(
    parameter NUM_BYTES = 2 ** 16
) (
    input logic clk_i,
    input logic rst_ni,

    //Masters
    input  obi_req_t  core_instr_req_i,
    output obi_resp_t core_instr_resp_o,

    input  obi_req_t  core_data_req_i,
    output obi_resp_t core_data_resp_o,

    input  obi_req_t  debug_master_req_i,
    output obi_resp_t debug_master_resp_o,

    //Slaves
    output obi_req_t  ram0_req_o,
    input  obi_resp_t ram0_resp_i,

    output obi_req_t  ram1_req_o,
    input  obi_resp_t ram1_resp_i,

    output obi_req_t  debug_slave_req_o,
    input  obi_resp_t debug_slave_resp_i,

    output obi_req_t  peripheral_slave_req_o,
    input  obi_resp_t peripheral_slave_resp_i

);

  import core_v_mini_mcu_pkg::*;


  typedef enum logic [1:0] {
    T_RAM,
    T_PER,
    T_ERR
  } transaction_t;
  transaction_t transaction, transaction_q;

  obi_req_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]   master_req;
  obi_resp_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]  master_resp;
  obi_req_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]    slave_req;
  obi_resp_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]   slave_resp;

  // signals for handshake
  logic data_rvalid_q;

  logic perip_gnt;

  // signals to print peripheral
  logic [31:0] print_wdata;
  logic print_valid;

  // signature data
  logic [31:0] sig_end_d, sig_end_q;
  logic [31:0] sig_begin_d, sig_begin_q;

  // signals to timer
  logic [31:0] timer_cnt_q;
  logic        timer_val_valid;
  logic [31:0] timer_wdata;

  //master req
  assign master_req[core_v_mini_mcu_pkg::CORE_INSTR_IDX] = core_instr_req_i;
  assign master_req[core_v_mini_mcu_pkg::CORE_DATA_IDX] = core_data_req_i;
  assign master_req[core_v_mini_mcu_pkg::DEBUG_MASTER_IDX] = debug_master_req_i;

  //master resp
  assign core_instr_resp_o = master_resp[core_v_mini_mcu_pkg::CORE_INSTR_IDX];
  always_comb begin
    core_data_resp_o        = master_resp[core_v_mini_mcu_pkg::CORE_DATA_IDX];
    core_data_resp_o.gnt    = master_resp[core_v_mini_mcu_pkg::CORE_DATA_IDX].gnt | perip_gnt;
    core_data_resp_o.rvalid = data_rvalid_q;
  end
  assign debug_master_resp_o = master_resp[core_v_mini_mcu_pkg::DEBUG_MASTER_IDX];

  //slave req
  assign ram0_req_o = slave_req[core_v_mini_mcu_pkg::RAM0_IDX];
  assign ram1_req_o = slave_req[core_v_mini_mcu_pkg::RAM1_IDX];
  assign debug_slave_req_o = slave_req[core_v_mini_mcu_pkg::DEBUG_IDX];
  assign peripheral_slave_req_o = slave_req[core_v_mini_mcu_pkg::PERIPHERAL_IDX];

  //slave resp
  assign slave_resp[core_v_mini_mcu_pkg::RAM0_IDX] = ram0_resp_i;
  assign slave_resp[core_v_mini_mcu_pkg::RAM1_IDX] = ram1_resp_i;
  assign slave_resp[core_v_mini_mcu_pkg::DEBUG_IDX] = debug_slave_resp_i;
  assign slave_resp[core_v_mini_mcu_pkg::PERIPHERAL_IDX] = peripheral_slave_resp_i;
  assign slave_resp[core_v_mini_mcu_pkg::ERROR_IDX] = '0;

  // handle the mapping of read and writes to either memory or pseudo
  // peripherals (currently just a redirection of writes to stdout)
  always_comb begin
    perip_gnt       = '0;
    print_wdata     = '0;
    print_valid     = '0;
    timer_wdata     = '0;
    timer_val_valid = '0;
    sig_end_d       = sig_end_q;
    sig_begin_d     = sig_begin_q;
    transaction     = T_PER;

    if (core_data_req_i.req) begin
      if (core_data_req_i.we) begin  // handle writes
        if (core_data_req_i.addr == 32'h1000_0000) begin
          print_wdata = core_data_req_i.wdata;
          print_valid = core_data_req_i.req;
          perip_gnt   = 1'b1;
        end else if (core_data_req_i.addr == 32'h1500_0000) begin
          timer_wdata = core_data_req_i.wdata;
          perip_gnt   = 1'b1;

        end else if (core_data_req_i.addr == 32'h1500_0004) begin
          timer_wdata = core_data_req_i.wdata;
          timer_val_valid = '1;
          perip_gnt = 1'b1;

        end else if (core_data_req_i.addr[31:0] < NUM_BYTES) begin
          transaction = T_RAM;
          // out of bounds write
        end else if ((core_data_req_i.addr >=  PERIPHERAL_START_ADDRESS && core_data_req_i.addr < PERIPHERAL_END_ADDRESS)) begin
          transaction = T_PER;
          //grant from debug
        end

      end else begin  // handle reads
        if (core_data_req_i.addr[31:0] == 32'h1500_1000) begin
          transaction = T_PER;
          perip_gnt   = 1'b1;
        end else if (core_data_req_i.addr[31:0] < NUM_BYTES) begin
          // out of bounds write
          transaction = T_RAM;
        end else if ((core_data_req_i.addr >= PERIPHERAL_START_ADDRESS && core_data_req_i.addr < PERIPHERAL_END_ADDRESS)) begin
          transaction = T_PER;
          //grant from debug
        end else begin
          transaction = T_ERR;
          $display("core add is %08x and max should be %08x", core_data_req_i.addr, NUM_BYTES);
        end
      end
    end
  end

`ifndef SYNTHESIS
`ifndef VERILATOR
  // signal out of bound writes
  out_of_bounds_write :
  assert property
    (@(posedge clk_i) disable iff (~rst_ni)
     (core_data_req_i.req && core_data_req_i.we |-> core_data_req_i.addr < core_v_mini_mcu_pkg::MEM_SIZE
      || core_data_req_i.addr == 32'h1000_0000
      || core_data_req_i.addr == 32'h1500_0000
      || core_data_req_i.addr == 32'h1500_0004
      || (core_data_req_i.addr >= PERIPHERAL_START_ADDRESS && core_data_req_i.addr < PERIPHERAL_END_ADDRESS)
     )

     )
  else $fatal("out of bounds write to %08x with %08x", core_data_req_i.addr, core_data_req_i.wdata);
`endif

  // make sure we select the proper read data
  always_comb begin : read_mux
    if (transaction_q == T_ERR) begin
      $display("out of bounds read from %08x", core_data_req_i.addr);
      $fatal(2);
    end
  end

  // print to stdout pseudo peripheral
  always_ff @(posedge clk_i, negedge rst_ni) begin : print_peripheral
    if (print_valid) begin
      if ($test$plusargs("verbose") != 0) begin
        if (32 <= print_wdata && print_wdata < 128) $display("OUT: '%c'", print_wdata[7:0]);
        else $display("OUT: %3d", print_wdata);

      end else begin
        $write("%c", print_wdata[7:0]);
`ifndef VERILATOR
        $fflush();
`endif
      end
    end
  end

`endif

  // Control timer. We need one to have some kind of timeout for tests that
  // get stuck in some loop. The riscv-tests also mandate that. Enable timer
  // interrupt by writing 1 to timer_irq_mask_q. Write initial value to
  // timer_cnt_q which gets counted down each cycle. When it transitions from
  // 1 to 0, and interrupt request (irq_q) is made (masked by timer_irq_mask_q).
  always_ff @(posedge clk_i, negedge rst_ni) begin : tb_timer
    if (~rst_ni) begin
      timer_cnt_q <= '0;
    end else begin

      // write timer value
      if (timer_val_valid) begin
        timer_cnt_q <= timer_wdata;

      end else begin
        if (timer_cnt_q > 0) timer_cnt_q <= timer_cnt_q - 1;
      end
    end
  end

`ifndef SYNTHESIS
  // show writes if requested
  always_ff @(posedge clk_i, negedge rst_ni) begin : verbose_writes
    if ($test$plusargs("verbose") != 0 && core_data_req_i.req && core_data_req_i.we)
      $display("write addr=0x%08x: data=0x%08x", core_data_req_i.addr, core_data_req_i.wdata);
  end
`endif


  system_xbar system_xbar_i (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .master_req_i(master_req),
      .master_resp_o(master_resp),
      .slave_req_o(slave_req),
      .slave_resp_i(slave_resp)
  );



  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      data_rvalid_q <= '0;
    end else begin
      data_rvalid_q <= core_data_resp_o.gnt;
    end
  end

  // signature range
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      sig_end_q   <= '0;
      sig_begin_q <= '0;
    end else begin
      sig_end_q   <= sig_end_d;
      sig_begin_q <= sig_begin_d;
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      transaction_q <= T_RAM;
    end else begin
      transaction_q <= transaction;
    end
  end


endmodule  // ram