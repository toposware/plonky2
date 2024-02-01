global main:
    PUSH @SEGMENT_REGISTERS_STATES
    // stack: addr_registers
    // First, set the registers correctly and verify their values.
    PUSH 2
    %stack_length SUB
    // stack: prev_stack_len, addr_registers
    // First, check the stack length.
    DUP1
    DUP3 %add_const(2) 
    // stack: stack_len_addr, prev_stack_len, prev_stack_len, addr_registers
    MLOAD_GENERAL
    %assert_eq

    // Now, we want to check the stack top. For this, we load
    // the value at offset (prev_stack_len - 1) * (stack_len > 0),
    // since we do not constrain the stack top when the stack is empty.
    // stack: prev_stack_len, addr_registers
    DUP1 PUSH 0 LT
    // stack: 0 < prev_stack_len, prev_stack_len, addr_registers
    PUSH 1 DUP3 SUB
    // stack: prev_stack_len - 1, 0 < prev_stack_len, prev_stack_len, addr_registers
    MUL
    PUSH @SEGMENT_STACK
    GET_CONTEXT
    %build_address
    // stack: stack_top_addr, prev_stack_len, addr_registers
    MLOAD_GENERAL

    // stack: stack_top, prev_stack_len, addr_registers
    DUP3 %add_const(3)
    MLOAD_GENERAL
    // stack: pv_stack_top, stack_top, prev_stack_len, addr_registers
    SUB
    // If the stack length was previously 0, we do not need to check the previous stack top.
    MUL
    // stack: (pv_stack_top - stack_top) * prev_stack_len, addr_registers
    %assert_zero

    // Check the context.
    GET_CONTEXT
    // stack: context, addr_registers
    DUP2 %add_const(4)
    MLOAD_GENERAL
    // stack: stored_context, context, addr_registers
    %assert_eq

    // Check the program counter.
    DUP1 %add_const(12)
    // stack: exit_info_addr, addr_registers
    MLOAD_GENERAL
    // stack: exit_info, addr_registers
    // Now, get the program counter.
    // The program counter is written in the first 32 bits of exit_info.
    DUP1 PUSH 0xFFFFFFFF AND
    // stack: program_counter, exit_info, addr_registers
    DUP3 MLOAD_GENERAL
    // stack: stored_pc, program_counter, exit_info, addr_registers
    %assert_eq

    // Check is_kernel_mode.
    // is_kernel_mode is written in the next 32 bits of exit_info.
    DUP1 %shr_const(32)
    PUSH 0xFFFFFFFF AND
    // stack: is_kernel_mode, exit_info, addr_registers
    DUP3 %increment MLOAD_GENERAL
    %assert_eq

    // Check the gas used.
    // The gas is written in the last 32 bits of exit_info.
    // stack: exit_info, addr_registers
    SWAP1
    // stack: addr_registers, exit_info
    DUP2 %shr_const(192)
    PUSH 0xFFFFFFFF AND
    // stack: gas_used, addr_registers, exit_info
    SWAP1 %add_const(5) MLOAD_GENERAL
    %assert_eq

    // stack: exit_info
    // Now, we set the PC to the correct values and continue the execution.
    EXIT_KERNEL

global main_contd:
    // First, hash the kernel code
    // Start with PUSH0 to avoid having a BytePacking operation at timestamp 0.
    // Timestamp 0 is reserved for memory initialization.
    %mload_global_metadata(@GLOBAL_METADATA_KERNEL_LEN)
    PUSH 0
    // stack: addr, len
    KECCAK_GENERAL
    // stack: hash
    %mload_global_metadata(@GLOBAL_METADATA_KERNEL_HASH)
    // stack: expected_hash, hash
    %assert_eq

    // Initialize the RLP DATA pointer to its initial position (ctx == virt == 0, segment = RLP)
    PUSH @SEGMENT_RLP_RAW
    %mstore_global_metadata(@GLOBAL_METADATA_RLP_DATA_SIZE)

    // Encode constant nodes
    %initialize_rlp_segment
   
    // Initialize the state, transaction and receipt trie root pointers.
    PROVER_INPUT(trie_ptr::state)
    %mstore_global_metadata(@GLOBAL_METADATA_STATE_TRIE_ROOT)
    PROVER_INPUT(trie_ptr::txn)
    %mstore_global_metadata(@GLOBAL_METADATA_TXN_TRIE_ROOT)
    PROVER_INPUT(trie_ptr::receipt)
    %mstore_global_metadata(@GLOBAL_METADATA_RECEIPT_TRIE_ROOT)

global hash_initial_tries:
    // We compute the length of the trie data segment in `mpt_hash` so that we
    // can check the value provided by the prover.
    // We initialize the segment length with 1 because the segment contains 
    // the null pointer `0` when the tries are empty.
    PUSH 1
    %mpt_hash_state_trie  %mload_global_metadata(@GLOBAL_METADATA_STATE_TRIE_DIGEST_BEFORE)    %assert_eq
    // stack: trie_data_len
    %mpt_hash_txn_trie     %mload_global_metadata(@GLOBAL_METADATA_TXN_TRIE_DIGEST_BEFORE)      %assert_eq
    // stack: trie_data_len
    %mpt_hash_receipt_trie %mload_global_metadata(@GLOBAL_METADATA_RECEIPT_TRIE_DIGEST_BEFORE)  %assert_eq
    // stack: trie_data_full_len
    %mstore_global_metadata(@GLOBAL_METADATA_TRIE_DATA_SIZE)

global start_txn:
    // stack: (empty)
    // The special case of an empty trie (i.e. for the first transaction)
    // is handled outside of the kernel.
    %mload_global_metadata(@GLOBAL_METADATA_TXN_NUMBER_BEFORE)
    // stack: txn_nb
    %mload_global_metadata(@GLOBAL_METADATA_BLOCK_GAS_USED_BEFORE)
    // stack: init_used_gas, txn_nb
    DUP2 %scalar_to_rlp
    // stack: txn_counter, init_gas_used, txn_nb
    DUP1 %num_bytes %mul_const(2)
    // stack: num_nibbles, txn_counter, init_gas_used, txn_nb
    SWAP2
    // stack: init_gas_used, txn_counter, num_nibbles, txn_nb

    // If the prover has no txn for us to process, halt.
    PROVER_INPUT(no_txn)
    %jumpi(execute_withdrawals)

    // Call route_txn. When we return, we will process the txn receipt.
    PUSH txn_after
    // stack: retdest, prev_gas_used, txn_counter, num_nibbles, txn_nb
    DUP4 DUP4 %increment_bounded_rlp
    %stack (next_txn_counter, next_num_nibbles, retdest, prev_gas_used, txn_counter, num_nibbles) -> (txn_counter, num_nibbles, retdest, prev_gas_used, txn_counter, num_nibbles, next_txn_counter, next_num_nibbles)
    %jump(route_txn)

global txn_after:
    // stack: success, leftover_gas, cur_cum_gas, prev_txn_counter, prev_num_nibbles, txn_counter, num_nibbles, txn_nb
    %process_receipt
    // stack: new_cum_gas, txn_counter, num_nibbles, txn_nb
    SWAP3 %increment SWAP3

global execute_withdrawals:
    // stack: cum_gas, txn_counter, num_nibbles, txn_nb
    %withdrawals
global hash_final_tries:
    // stack: cum_gas, txn_counter, num_nibbles, txn_nb
    // Check that we end up with the correct `cum_gas`, `txn_nb` and bloom filter.
    %mload_global_metadata(@GLOBAL_METADATA_BLOCK_GAS_USED_AFTER) %assert_eq
    DUP3 %mload_global_metadata(@GLOBAL_METADATA_TXN_NUMBER_AFTER) %assert_eq
    %pop3
    PUSH 1 // initial trie data length 
    %mpt_hash_state_trie   %mload_global_metadata(@GLOBAL_METADATA_STATE_TRIE_DIGEST_AFTER)     %assert_eq
    %mpt_hash_txn_trie     %mload_global_metadata(@GLOBAL_METADATA_TXN_TRIE_DIGEST_AFTER)       %assert_eq
    %mpt_hash_receipt_trie %mload_global_metadata(@GLOBAL_METADATA_RECEIPT_TRIE_DIGEST_AFTER)   %assert_eq
    // We don't need the trie data length here.
    POP
    %jump(halt)
