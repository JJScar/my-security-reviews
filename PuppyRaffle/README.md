# PuppyRaffle - Pracitce Audit by Cyfrin 

This repository contains a practice audit of a smart contract designed for a raffle application. The audit focuses on identifying potential vulnerabilities and testing the contract's functionality against various attack scenarios.

## Purpose

The purpose of this audit is to practice identifying and understanding potential security issues in smart contracts. By analyzing the raffle contract, we aim to:

- Identify vulnerabilities that could lead to loss of funds or exploitation.
- Test the contract's functionality under different scenarios.
- Gain practical experience in auditing Solidity smart contracts.

## Contract Overview

The smart contract under audit, `PuppyRaffle.sol`, implements a raffle system where participants can enter with a fee and potentially win rewards based on a random selection process.

Key functionalities include:
- Entering the raffle with an entrance fee.
- Refunding participants if they change their mind.
- Selecting winners and distributing rewards.
- Handling fees for the protocol.

## Audit Focus

### Attack Vectors Explored

The audit explores various attack vectors including:
- **Denial of Service (DoS)**: Assessing gas costs and potential inefficiencies in the contract's logic that could be exploited.
- **Reentrancy Attacks**: Checking for any reentrancy vulnerabilities where an external contract could manipulate state changes unexpectedly.
- **Integer Overflow/Underflow**: Analyzing arithmetic operations to ensure they are safe from overflow/underflow vulnerabilities.
- **Logic Bugs**: Identifying any logical flaws that could allow unauthorized access or manipulation of contract behavior.

## Test Cases

The repository includes test cases designed to:
- Validate expected behaviors under normal conditions.
- Simulate potential attack scenarios to assess contract robustness.
- Verify edge cases to ensure contract handles all possible inputs correctly.

## Conclusion

This audit is for educational purposes and aims to improve understanding of smart contract security best practices. Results and findings are documented in the repository for review and further discussion.

For questions or feedback, please contact [Your Name] at [Your Contact Information].

