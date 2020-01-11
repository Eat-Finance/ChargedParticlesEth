pragma solidity ^0.5.13;
pragma experimental ABIEncoderV2;

import "./ERC1155MixedFungibleMintable.sol";
import "multi-token-standard/contracts/interfaces/IERC20.sol";
import "multi-token-standard/contracts/interfaces/IERC1155.sol";
import "multi-token-standard/contracts/utils/LibBytes.sol";
import "multi-token-standard/contracts/utils/SignatureValidator.sol";


/**
 * @dev ERC-1155 with native metatransaction methods. These additional functions allow users
 *      to presign function calls and allow third parties to execute these on their behalf
 *
 * Note: This contract is identical to the ERC1155Meta.sol contract,
 *       except for the ERC1155PackedBalance parent contract.
 */
contract ERC1155MetaMixedFungible is ERC1155MixedFungibleMintable, SignatureValidator {
    using LibBytes for bytes;

    /***********************************|
    |       Variables and Structs       |
    |__________________________________*/

    /**
     * Gas Receipt
     *   feeTokenData : (bool, address, ?unit256)
     *     1st element should be the address of the token
     *     2nd argument (if ERC-1155) should be the ID of the token
     *     Last element should be a 0x0 if ERC-20 and 0x1 for ERC-1155
     */
    struct GasReceipt {
        uint256 gasLimit;     // Max amount of gas that can be reimbursed
        uint256 baseGas;      // Base gas cost (includes things like 21k, CALLDATA size, etc.)
        uint256 gasPrice;     // Price denominated in token X per gas unit
        address feeRecipient; // Address to send payment to
        bytes feeTokenData;   // Data for token to pay for gas as `uint256(tokenAddress)`
    }

    // Which token standard is used to pay gas fee
    enum FeeTokenType {
        ERC1155,    // 0x00, ERC-1155 token - DEFAULT
        ERC20,      // 0x01, ERC-20 token
        NTypes      // 0x02, number of signature types. Always leave at end.
    }

    // Signature nonce per address
    mapping (address => uint256) internal nonces;


    /***********************************|
    |               Events              |
    |__________________________________*/

    event NonceChange(address indexed signer, uint256 newNonce);


    /****************************************|
    |     Public Meta Transfer Functions     |
    |_______________________________________*/

    /**
     * @notice Allows anyone with a valid signature to transfer _amount amount of a token _id on the bahalf of _from
     * @param _from     Source address
     * @param _to       Target address
     * @param _id       ID of the token type
     * @param _amount   Transfered amount
     * @param _isGasFee Whether gas is reimbursed to executor or not
     * @param _data     Encodes a meta transfer indicator, signature, gas payment receipt and extra transfer data
     *   _data should be encoded as (
     *   (bytes32 r, bytes32 s, uint8 v, uint256 nonce, SignatureType sigType),
     *   (GasReceipt g, ?bytes transferData)
     * )
     *   i.e. high level encoding should be (bytes, bytes), where the latter bytes array is a nested bytes array
     */
    function metaSafeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        uint256 _amount,
        bool _isGasFee,
        bytes memory _data)
    public
    {
        require(_to != address(0), "ERC1155MetaMixedFungible#metaSafeTransferFrom: INVALID_RECIPIENT");

        // Starting gas amount
        uint256 startGas = gasleft();
        bytes memory transferData;
        GasReceipt memory gasReceipt;

        // Verify signature and extract the signed data
        bytes memory signedData = _signatureValidation(
            _from,
            _data,
            abi.encodePacked(
                META_TX_TYPEHASH,
                uint256(_from),  // Address as uint256
                uint256(_to),    // Address as uint256
                _id,
                _amount
            )
        );

        // If Gas is being reimbursed
        if (_isGasFee) {
            (gasReceipt, transferData) = abi.decode(signedData, (GasReceipt, bytes));
            _safeTransferFrom(_from, _to, _id, _amount);

            // Check if recipient is contract
            if (_to.isContract()) {
                // We need to somewhat protect operators against gas griefing attacks in recipient contract.
                // Hence we only pass the gasLimit to the recipient such that the validator knows the griefing
                // limit. Nothing can prevent the receiver to revert the transaction as close to the gasLimit as
                // possible, but the operator can now only accept meta-transaction gasLimit within a certain range.
                bytes4 retval = IERC1155TokenReceiver(_to).onERC1155Received.gas(gasReceipt.gasLimit)(msg.sender, _from, _id, _amount, transferData);
                require(retval == ERC1155_RECEIVED_VALUE, "ERC1155MetaMixedFungible#metaSafeTransferFrom: INVALID_ON_RECEIVE_MESSAGE");
            }

            // Transfer gas cost
            _transferGasFee(_from, startGas, gasReceipt);

        } else {
            _safeTransferFrom(_from, _to, _id, _amount);
            _callonERC1155Received(_from, _to, _id, _amount, signedData);
        }
    }

    /**
     * @notice Allows anyone with a valid signature to transfer multiple types of tokens on the bahalf of _from
     * @param _from     Source addresses
     * @param _to       Target addresses
     * @param _ids      IDs of each token type
     * @param _amounts  Transfer amounts per token type
     * @param _data     Encodes a meta transfer indicator, signature, gas payment receipt and extra transfer data
     *   _data should be encoded as (
     *   (bytes32 r, bytes32 s, uint8 v, uint256 nonce, SignatureType sigType),
     *   (GasReceipt g, ?bytes transferData)
     * )
     *   i.e. high level encoding should be (bytes, bytes), where the latter bytes array is a nested bytes array
     */
    function metaSafeBatchTransferFrom(
        address _from,
        address _to,
        uint256[] memory _ids,
        uint256[] memory _amounts,
        bool _isGasFee,
        bytes memory _data)
    public
    {
        require(_to != address(0), "ERC1155MetaMixedFungible#metaSafeBatchTransferFrom: INVALID_RECIPIENT");

        // Starting gas amount
        uint256 startGas = gasleft();
        bytes memory transferData;
        GasReceipt memory gasReceipt;

        // Verify signature and extract the signed data
        bytes memory signedData = _signatureValidation(
            _from,
            _data,
            abi.encodePacked(
                META_BATCH_TX_TYPEHASH,
                uint256(_from), // Address as uint256
                uint256(_to),   // Address as uint256
                keccak256(abi.encodePacked(_ids)),
                keccak256(abi.encodePacked(_amounts))
            )
        );

        // If gas fee being reimbursed
        if (_isGasFee) {
            (gasReceipt, transferData) = abi.decode(signedData, (GasReceipt, bytes));

            // Update balances
            _safeBatchTransferFrom(_from, _to, _ids, _amounts);

            // Check if recipient is contract
            if (_to.isContract()) {
                // We need to somewhat protect operators against gas griefing attacks in recipient contract.
                // Hence we only pass the gasLimit to the recipient such that the validator knows the griefing
                // limit. Nothing can prevent the receiver to revert the transaction as close to the gasLimit as
                // possible, but the operator can now only accept meta-transaction gasLimit within a certain range.
                bytes4 retval = IERC1155TokenReceiver(_to).onERC1155BatchReceived.gas(gasReceipt.gasLimit)(msg.sender, _from, _ids, _amounts, transferData);
                require(retval == ERC1155_BATCH_RECEIVED_VALUE, "ERC1155MetaMixedFungible#metaSafeBatchTransferFrom: INVALID_ON_RECEIVE_MESSAGE");
            }

            // Handle gas reimbursement
            _transferGasFee(_from, startGas, gasReceipt);

        } else {
            _safeBatchTransferFrom(_from, _to, _ids, _amounts);
            _callonERC1155BatchReceived(_from, _to, _ids, _amounts, signedData);
        }
    }


    /***********************************|
    |         Operator Functions        |
    |__________________________________*/

    /**
     * @notice Approve the passed address to spend on behalf of _from if valid signature is provided
     * @param _owner     Address that wants to set operator status  _spender
     * @param _operator  Address to add to the set of authorized operators
     * @param _approved  True if the operator is approved, false to revoke approval
     * @param _isGasFee  Whether gas will be reimbursed or not, with vlid signature
     * @param _data      Encodes signature and gas payment receipt
     *   _data should be encoded as (
     *     (bytes32 r, bytes32 s, uint8 v, uint256 nonce, SignatureType sigType),
     *     (GasReceipt g)
     *   )
     *   i.e. high level encoding should be (bytes, bytes), where the latter bytes array is a nested bytes array
     */
    function metaSetApprovalForAll(
        address _owner,
        address _operator,
        bool _approved,
        bool _isGasFee,
        bytes memory _data)
    public
    {
        // Starting gas amount
        uint256 startGas = gasleft();

        // Verify signature and extract the signed data
        bytes memory signedData = _signatureValidation(
            _owner,
            _data,
            abi.encodePacked(
                META_APPROVAL_TYPEHASH,
                uint256(_owner),                    // Address as uint256
                uint256(_operator),                 // Address as uint256
                _approved ? uint256(1) : uint256(0) // Boolean as uint256
            )
        );

        // Update operator status
        operators[_owner][_operator] = _approved;

        // Emit event
        emit ApprovalForAll(_owner, _operator, _approved);

        // Handle gas reimbursement
        if (_isGasFee) {
            GasReceipt memory gasReceipt = abi.decode(signedData, (GasReceipt));
            _transferGasFee(_owner, startGas, gasReceipt);
        }
    }


    /****************************************|
    |      Signture Validation Functions     |
    |_______________________________________*/

    // keccak256(
    //   "metaSafeTransferFrom(address _from,address _to,uint256 _id,uint256 _amount,uint256 nonce,bytes signedData)"
    // );
    bytes32 internal constant META_TX_TYPEHASH = 0xda41aee141786e5a994acb21bcafccf68ed6e07786cb44008c785a06f2819038;

    // keccak256(
    //   "metaSafeBatchTransferFrom(address _from,address _to,uint256[] _ids,uint256[] _amounts,uint256 nonce,bytes signedData)"
    // );
    bytes32 internal constant META_BATCH_TX_TYPEHASH = 0xa358be8ef28a8eef7877f5d78ce30ff1cada344474e3d550ee9f4be9151f84f7;

    // keccak256(
    //   "metaSetApprovalForAll(address _owner,address _operator,bool _approved,uint256 nonce,bytes signedData)"
    // );
    bytes32 internal constant META_APPROVAL_TYPEHASH = 0xd72d507eb90d918a375b250ea7bfc291be59526e94e2baa2fe3b35daa72a0b15;

    /**
     * @notice Verifies signatures for this contract
     * @param _signer     Address of signer
     * @param _sigData    Encodes signature, gas payment receipt and transfer data (if any)
     * @param _encMembers Encoded EIP-712 type members (except nonce and _data), all need to be 32 bytes size
     * @dev _data should be encoded as (
     *   (bytes32 r, bytes32 s, uint8 v, uint256 nonce, SignatureType sigType),
     *   (GasReceipt g, ?bytes transferData)
     * )
     *   i.e. high level encoding svhould be (bytes, bytes), where the latter bytes array is a nested bytes array
     */
    function _signatureValidation(
        address _signer,
        bytes memory _sigData,
        bytes memory _encMembers)
    internal returns (bytes memory signedData)
    {
        bytes memory sig;

        // Get signature and data to sign
        (sig, signedData) = abi.decode(_sigData, (bytes, bytes));

        // Get current nonce and nonce used for signature
        uint256 currentNonce = nonces[_signer];        // Lowest valid nonce for signer
        uint256 nonce = uint256(sig.readBytes32(65));  // Nonce passed in the signature object

        // Verify if nonce is valid
        require(
            (nonce >= currentNonce) && (nonce < (currentNonce + 100)),
            "ERC1155MetaMixedFungible#_signatureValidation: INVALID_NONCE"
        );

        // Take hash of bytes arrays
        bytes32 hash = hashEIP712Message(keccak256(abi.encodePacked(_encMembers, nonce, keccak256(signedData))));

        // Complete data to pass to signer verifier
        bytes memory fullData = abi.encodePacked(_encMembers, nonce, signedData);

        // Verify if _from is the signer
        require(isValidSignature(_signer, hash, fullData, sig), "ERC1155MetaMixedFungible#_signatureValidation: INVALID_SIGNATURE");

        //Update signature nonce
        nonces[_signer] = nonce + 1;
        emit NonceChange(_signer, nonce + 1);

        return signedData;
    }

    /**
     * @notice Returns the current nonce associated with a given address
     * @param _signer Address to query signature nonce for
     */
    function getNonce(address _signer)
    public view returns (uint256 nonce)
    {
        return nonces[_signer];
    }


    /***********************************|
    |    Gas Reimbursement Functions    |
    |__________________________________*/

    /**
     * @notice Will reimburse tx.origin or fee recipient for the gas spent execution a transaction
     *         Can reimbuse in any ERC-20 or ERC-1155 token
     * @param _from      Address from which the payment will be made from
     * @param _startGas  The gas amount left when gas counter started
     * @param _g         GasReceipt object that contains gas reimbursement information
     */
    function _transferGasFee(address _from, uint256 _startGas, GasReceipt memory _g)
    internal
    {
        // Pop last byte to get token fee type
        uint8 feeTokenTypeRaw = uint8(_g.feeTokenData.popLastByte());

        // Ensure valid fee token type
        require(
            feeTokenTypeRaw < uint8(FeeTokenType.NTypes),
            "ERC1155MetaMixedFungible#_transferGasFee: UNSUPPORTED_TOKEN"
        );

        // Convert to FeeTokenType corresponding value
        FeeTokenType feeTokenType = FeeTokenType(feeTokenTypeRaw);

        // Declarations
        address tokenAddress;
        address feeRecipient;
        uint256 gasUsed;
        uint256 tokenID;
        uint256 fee;

        // Amount of gas consumed
        gasUsed = _startGas.sub(gasleft()).add(_g.baseGas);

        // Reimburse up to gasLimit (instead of throwing)
        fee = gasUsed > _g.gasLimit ? _g.gasLimit.mul(_g.gasPrice) : gasUsed.mul(_g.gasPrice);

        // If receiver is 0x0, then anyone can claim, otherwise, refund addresse provided
        feeRecipient = _g.feeRecipient == address(0) ? msg.sender : _g.feeRecipient;

        // Fee token is ERC1155
        if (feeTokenType == FeeTokenType.ERC1155 ) {
            (tokenAddress, tokenID) = abi.decode(_g.feeTokenData, (address, uint256));

            // Fee is paid from this ERC1155 contract
            if (tokenAddress == address(this)) {
                _safeTransferFrom(_from, feeRecipient, tokenID, fee);

                // No need to protect against griefing since recipient contract is most likely the operator
                _callonERC1155Received(_from, feeRecipient, tokenID, fee, "");

                // Fee is paid from another ERC-1155 contract
            } else {
                IERC1155(tokenAddress).safeTransferFrom(_from, feeRecipient, tokenID, fee, "");
            }

            // Fee token is ERC20
        } else {
            tokenAddress = abi.decode(_g.feeTokenData, (address));
            require(
                IERC20(tokenAddress).transferFrom(_from, feeRecipient, fee),
                "ERC1155MetaMixedFungible#_transferGasFee: ERC20_TRANSFER_FAILED"
            );
        }
    }
}
