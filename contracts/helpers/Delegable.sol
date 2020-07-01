pragma solidity ^0.6.2;


/// @dev Delegable enables users to delegate their account management to delegated
contract Delegable {
    // All delegated can be known from events for audit purposes
    event Delegate(address indexed user, address indexed delegate, bool enabled);

    mapping(address => mapping(address => bool)) internal delegated;

    /// @dev Require that tx.origin is the account holder or a delegate
    modifier onlyHolderOrDelegate(address holder, string memory errorMessage) {
        require(
            msg.sender == holder || delegated[holder][msg.sender],
            errorMessage
        );
        _;
    }

    /// @dev Enable a delegate to act on the behalf of caller
    function addDelegate(address delegate) public {
        delegated[msg.sender][delegate] = true;
        emit Delegate(msg.sender, delegate, true);
    }

    /// @dev Stop a delegate from acting on the behalf of caller
    function revokeDelegate(address delegate) public {
        delegated[msg.sender][delegate] = false;
        emit Delegate(msg.sender, delegate, false);
    }
}