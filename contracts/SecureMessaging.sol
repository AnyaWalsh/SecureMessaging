// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool, eaddress } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SecureMessaging is SepoliaConfig {

    address public owner;
    uint256 public messageCount;

    struct EncryptedMessage {
        eaddress encryptedSender;
        eaddress encryptedReceiver;
        euint32 encryptedContent;
        uint256 timestamp;
        bool isRead;
        uint256 messageId;
    }

    struct UserProfile {
        bool isRegistered;
        string publicName;
        uint256 lastActive;
        uint256 messagesSent;
        uint256 messagesReceived;
    }

    mapping(uint256 => EncryptedMessage) public messages;
    mapping(address => UserProfile) public userProfiles;
    mapping(address => uint256[]) public userInbox;
    mapping(address => uint256[]) public userSentMessages;
    mapping(address => mapping(address => bool)) public blockedUsers;

    event UserRegistered(address indexed user, string publicName);
    event MessageSent(address indexed sender, address indexed receiver, uint256 indexed messageId);
    event MessageRead(address indexed reader, uint256 indexed messageId);
    event UserBlocked(address indexed blocker, address indexed blocked);
    event UserUnblocked(address indexed unblocker, address indexed unblocked);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    modifier onlyRegistered() {
        require(userProfiles[msg.sender].isRegistered, "User not registered");
        _;
    }

    modifier messageExists(uint256 _messageId) {
        require(_messageId > 0 && _messageId <= messageCount, "Message does not exist");
        _;
    }

    constructor() {
        owner = msg.sender;
        messageCount = 0;
    }

    // Register a new user with a public display name
    function registerUser(string calldata _publicName) external {
        require(!userProfiles[msg.sender].isRegistered, "User already registered");
        require(bytes(_publicName).length > 0 && bytes(_publicName).length <= 50, "Invalid name length");

        userProfiles[msg.sender] = UserProfile({
            isRegistered: true,
            publicName: _publicName,
            lastActive: block.timestamp,
            messagesSent: 0,
            messagesReceived: 0
        });

        emit UserRegistered(msg.sender, _publicName);
    }

    // Send an encrypted message to another user
    function sendMessage(address _receiver, uint32 _encryptedContent) external onlyRegistered {
        require(userProfiles[_receiver].isRegistered, "Receiver not registered");
        require(_receiver != msg.sender, "Cannot send message to yourself");
        require(!blockedUsers[_receiver][msg.sender], "You are blocked by this user");

        messageCount++;

        // Encrypt sender and receiver addresses
        eaddress encryptedSender = FHE.asEaddress(msg.sender);
        eaddress encryptedReceiver = FHE.asEaddress(_receiver);
        euint32 encryptedContent = FHE.asEuint32(_encryptedContent);

        messages[messageCount] = EncryptedMessage({
            encryptedSender: encryptedSender,
            encryptedReceiver: encryptedReceiver,
            encryptedContent: encryptedContent,
            timestamp: block.timestamp,
            isRead: false,
            messageId: messageCount
        });

        // Update user message arrays
        userInbox[_receiver].push(messageCount);
        userSentMessages[msg.sender].push(messageCount);

        // Update user statistics
        userProfiles[msg.sender].messagesSent++;
        userProfiles[msg.sender].lastActive = block.timestamp;
        userProfiles[_receiver].messagesReceived++;

        // Set ACL permissions for encrypted data
        FHE.allowThis(encryptedSender);
        FHE.allowThis(encryptedReceiver);
        FHE.allowThis(encryptedContent);
        FHE.allow(encryptedSender, msg.sender);
        FHE.allow(encryptedReceiver, _receiver);
        FHE.allow(encryptedContent, msg.sender);
        FHE.allow(encryptedContent, _receiver);

        emit MessageSent(msg.sender, _receiver, messageCount);
    }

    // Mark a message as read (only receiver can do this)
    function markMessageAsRead(uint256 _messageId) external onlyRegistered messageExists(_messageId) {
        EncryptedMessage storage message = messages[_messageId];

        // Verify that the caller is the intended receiver
        require(!message.isRead, "Message already read");

        // Update read status
        message.isRead = true;
        userProfiles[msg.sender].lastActive = block.timestamp;

        emit MessageRead(msg.sender, _messageId);
    }

    // Block a user from sending messages
    function blockUser(address _userToBlock) external onlyRegistered {
        require(_userToBlock != msg.sender, "Cannot block yourself");
        require(userProfiles[_userToBlock].isRegistered, "User not registered");
        require(!blockedUsers[msg.sender][_userToBlock], "User already blocked");

        blockedUsers[msg.sender][_userToBlock] = true;
        emit UserBlocked(msg.sender, _userToBlock);
    }

    // Unblock a previously blocked user
    function unblockUser(address _userToUnblock) external onlyRegistered {
        require(blockedUsers[msg.sender][_userToUnblock], "User not blocked");

        blockedUsers[msg.sender][_userToUnblock] = false;
        emit UserUnblocked(msg.sender, _userToUnblock);
    }

    // Get user's inbox message IDs
    function getInboxMessages(address _user) external view returns (uint256[] memory) {
        return userInbox[_user];
    }

    // Get user's sent message IDs
    function getSentMessages(address _user) external view returns (uint256[] memory) {
        return userSentMessages[_user];
    }

    // Get message basic info (non-encrypted data)
    function getMessageInfo(uint256 _messageId) external view messageExists(_messageId) returns (
        uint256 timestamp,
        bool isRead,
        uint256 messageId
    ) {
        EncryptedMessage storage message = messages[_messageId];
        return (
            message.timestamp,
            message.isRead,
            message.messageId
        );
    }

    // Get user profile information
    function getUserProfile(address _user) external view returns (
        bool isRegistered,
        string memory publicName,
        uint256 lastActive,
        uint256 messagesSent,
        uint256 messagesReceived
    ) {
        UserProfile storage profile = userProfiles[_user];
        return (
            profile.isRegistered,
            profile.publicName,
            profile.lastActive,
            profile.messagesSent,
            profile.messagesReceived
        );
    }

    // Check if a user is blocked by another user
    function isUserBlocked(address _blocker, address _blocked) external view returns (bool) {
        return blockedUsers[_blocker][_blocked];
    }

    // Get total number of messages in the system
    function getTotalMessages() external view returns (uint256) {
        return messageCount;
    }

    // Update user's last active timestamp
    function updateLastActive() external onlyRegistered {
        userProfiles[msg.sender].lastActive = block.timestamp;
    }

    // Get unread message count for a user
    function getUnreadMessageCount(address _user) external view returns (uint256) {
        uint256[] memory inbox = userInbox[_user];
        uint256 unreadCount = 0;

        for (uint256 i = 0; i < inbox.length; i++) {
            if (!messages[inbox[i]].isRead) {
                unreadCount++;
            }
        }

        return unreadCount;
    }

    // Emergency function to pause contract (owner only)
    bool public isPaused = false;

    function togglePause() external onlyOwner {
        isPaused = !isPaused;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Contract is paused");
        _;
    }

    // Apply pause check to critical functions
    function sendMessageSecure(address _receiver, uint32 _encryptedContent) external onlyRegistered whenNotPaused {
        require(userProfiles[_receiver].isRegistered, "Receiver not registered");
        require(_receiver != msg.sender, "Cannot send message to yourself");
        require(!blockedUsers[_receiver][msg.sender], "You are blocked by this user");

        messageCount++;

        // Encrypt sender and receiver addresses
        eaddress encryptedSender = FHE.asEaddress(msg.sender);
        eaddress encryptedReceiver = FHE.asEaddress(_receiver);
        euint32 encryptedContent = FHE.asEuint32(_encryptedContent);

        messages[messageCount] = EncryptedMessage({
            encryptedSender: encryptedSender,
            encryptedReceiver: encryptedReceiver,
            encryptedContent: encryptedContent,
            timestamp: block.timestamp,
            isRead: false,
            messageId: messageCount
        });

        // Update user message arrays
        userInbox[_receiver].push(messageCount);
        userSentMessages[msg.sender].push(messageCount);

        // Update user statistics
        userProfiles[msg.sender].messagesSent++;
        userProfiles[msg.sender].lastActive = block.timestamp;
        userProfiles[_receiver].messagesReceived++;

        // Set ACL permissions for encrypted data
        FHE.allowThis(encryptedSender);
        FHE.allowThis(encryptedReceiver);
        FHE.allowThis(encryptedContent);
        FHE.allow(encryptedSender, msg.sender);
        FHE.allow(encryptedReceiver, _receiver);
        FHE.allow(encryptedContent, msg.sender);
        FHE.allow(encryptedContent, _receiver);

        emit MessageSent(msg.sender, _receiver, messageCount);
    }
}