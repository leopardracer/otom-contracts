// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin-contracts-5.0.0/proxy/ERC1967/ERC1967Proxy.sol";

import {Otoms} from "../src/Otoms.sol";
import {Annihilator} from "../src/Annihilator.sol";
import {OtomsEncoder} from "../src/OtomsEncoder.sol";
import {OtomsReactionOutputs} from "../src/ReactionOutputs.sol";
import {Energy} from "../src/Energy.sol";

import {Reactor} from "../src/Reactor.sol";

import {MiningPayload} from "../src/interfaces/IOtoms.sol";

import {OtomsDatabase} from "../src/OtomsDatabase.sol";

import {ReactionResult, MoleculeWithUri} from "../src/interfaces/IReactor.sol";

import {UniverseInformation, Atom, Molecule, Bond, Nucleus, AtomStructure} from "../src/interfaces/IOtomsDatabase.sol";

contract Helper {
    function getMessageHash(bytes32 message) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", message)
            );
    }

    function constructSignatureBytes(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public pure returns (bytes memory signature) {
        signature = new bytes(65);

        assembly {
            // Store `r` at the beginning of the `signature` array
            mstore(add(signature, 32), r)
            // Store `s` after `r`
            mstore(add(signature, 64), s)
            // Store `v` at the end (65th byte)
            mstore8(add(signature, 96), v)
        }
    }
}

contract OtomsTest is Test, Helper {
    Otoms public otoms;
    Energy public energy;
    Reactor public reactor;
    OtomsEncoder public encoder;
    Annihilator public annihilator;
    OtomsDatabase public database;
    OtomsReactionOutputs public reactionOutputs;

    uint256 internal _deployerKey = 1;
    uint256 internal _signerKey = 2;
    uint256 internal _eoaKey = 3;
    uint256 internal _user1Key = 4;
    uint256 internal _user2Key = 5;

    address public deployer = vm.addr(_deployerKey);
    address public signer = vm.addr(_signerKey);
    address public eoa = vm.addr(_eoaKey);
    address public user1 = vm.addr(_user1Key);
    address public user2 = vm.addr(_user2Key);

    UniverseInformation public universeInformation;

    string public unanalysedMoleculeUri;

    uint256 public expiry;

    function setUp() public {
        unanalysedMoleculeUri = "test.uri";

        expiry = block.timestamp + 2 days;

        bytes32 seedHash = bytes32(
            keccak256(
                abi.encodePacked(
                    "0xd32a7e1b8bf7d74b46040afd2e904aa78da77173ed7641a76ce55ace02d31757"
                )
            )
        );

        universeInformation = UniverseInformation({
            seedHash: seedHash,
            name: "test",
            active: true,
            energyFactorBps: 0
        });

        encoder = new OtomsEncoder();

        annihilator = new Annihilator();

        // deploy database
        address[] memory dbOperators = new address[](0);
        OtomsDatabase databaseImplementation = new OtomsDatabase();
        bytes memory databaseInit = abi.encodeWithSelector(
            OtomsDatabase.initialize.selector,
            dbOperators,
            address(encoder)
        );
        ERC1967Proxy databaseProxy = new ERC1967Proxy(
            address(databaseImplementation),
            databaseInit
        );
        database = OtomsDatabase(address(databaseProxy));

        // deploy reaction outputs
        OtomsReactionOutputs reactionOutputsImplementation = new OtomsReactionOutputs();
        bytes memory reactionOutputsInit = abi.encodeWithSelector(
            OtomsReactionOutputs.initialize.selector,
            address(database),
            "some-uri-a"
        );
        ERC1967Proxy reactionOutputsProxy = new ERC1967Proxy(
            address(reactionOutputsImplementation),
            reactionOutputsInit
        );
        reactionOutputs = OtomsReactionOutputs(address(reactionOutputsProxy));

        //deploy the reactor
        Reactor reactorImplementation = new Reactor();
        bytes memory reactorInit = abi.encodeWithSelector(
            Reactor.initialize.selector,
            address(signer),
            address(encoder),
            address(reactionOutputs),
            5
        );
        ERC1967Proxy reactorProxy = new ERC1967Proxy(
            address(reactorImplementation),
            reactorInit
        );
        reactor = Reactor(address(reactorProxy));

        //deploy the energy
        Energy energyImplementation = new Energy();
        bytes memory energyInit = abi.encodeWithSelector(
            Energy.initialize.selector
        );
        ERC1967Proxy energyProxy = new ERC1967Proxy(
            address(energyImplementation),
            energyInit
        );
        energy = Energy(address(energyProxy));

        //deploy the otoms
        address[] memory operators = new address[](2);
        operators[0] = address(reactor);
        operators[1] = address(annihilator);
        Otoms otomsImplementation = new Otoms();
        bytes memory otomsInit = abi.encodeWithSelector(
            Otoms.initialize.selector,
            operators,
            signer,
            address(encoder),
            address(database)
        );
        ERC1967Proxy otomsProxy = new ERC1967Proxy(
            address(otomsImplementation),
            otomsInit
        );
        otoms = Otoms(address(otomsProxy));

        energy.toggleOperator(address(reactor));
        energy.toggleOperator(address(annihilator));
        reactor.setOtoms(address(otoms));
        reactor.setEnergy(address(energy));
        annihilator.setOtoms(address(otoms));
        annihilator.setEnergy(address(energy));
        database.toggleOperator(address(otoms));
        database.toggleOperator(address(reactor));
        database.toggleOperator(address(annihilator));
        reactionOutputs.setReactor(address(reactor), true);
        otoms.setMiningPaused(false);
    }

    function test_seedUniverse() public {
        bytes32 seedUniverseHash = encoder.getSeedUniverseMessageHash(
            universeInformation,
            expiry,
            address(eoa)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _signerKey,
            getMessageHash(seedUniverseHash)
        );
        bytes memory seedUniverseSignature = constructSignatureBytes(v, r, s);

        vm.prank(eoa);
        otoms.seedUniverse(universeInformation, expiry, seedUniverseSignature);

        assertEq(
            database
                .getUniverseInformation(universeInformation.seedHash)
                .active,
            true
        );
    }

    function testFuzz_mine(
        uint256 nucleons,
        uint256 protons,
        uint256 neutrons
    ) public {
        //seed the universe
        bytes32 seedUniverseHash = encoder.getSeedUniverseMessageHash(
            universeInformation,
            expiry,
            address(eoa)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _signerKey,
            getMessageHash(seedUniverseHash)
        );
        bytes memory seedUniverseSignature = constructSignatureBytes(v, r, s);

        vm.prank(eoa);
        otoms.seedUniverse(universeInformation, expiry, seedUniverseSignature);

        uint256[] memory totalInOuter = new uint256[](2);
        totalInOuter[0] = 2;
        totalInOuter[1] = 2;

        uint256[] memory emptyInOuter = new uint256[](2);
        emptyInOuter[0] = 1;
        emptyInOuter[1] = 1;

        uint256[] memory filledInOuter = new uint256[](2);
        filledInOuter[0] = 2;
        filledInOuter[1] = 2;

        uint256[] memory ancestors = new uint256[](1);
        ancestors[0] = 1;

        AtomStructure memory structure = AtomStructure({
            universeHash: universeInformation.seedHash,
            depth: 3,
            distance: 4,
            distanceIndex: 4,
            shell: 2,
            totalInOuter: totalInOuter,
            emptyInOuter: emptyInOuter,
            filledInOuter: filledInOuter,
            ancestors: ancestors
        });

        Nucleus memory nucleus = Nucleus({
            protons: protons,
            neutrons: neutrons,
            nucleons: nucleons,
            stability: 40,
            decayType: "testDecay"
        });

        bytes32 creationHash = encoder.getMiningHash(
            address(eoa),
            universeInformation.seedHash,
            otoms.getMiningNonce(universeInformation.seedHash, address(eoa))
        );

        Bond memory bond = Bond({strength: 1, bondType: "testBondType"});

        Atom[] memory givingAtoms = new Atom[](1);
        givingAtoms[0] = Atom({
            radius: 4,
            volume: 10,
            mass: 100,
            density: 1,
            electronegativity: 1,
            name: "testName",
            structure: structure,
            nucleus: nucleus,
            metallic: false,
            series: "testSeries",
            periodicTableX: 1,
            periodicTableY: 1
        });

        Molecule memory molecule = Molecule({
            id: "a",
            activationEnergy: 1,
            radius: 4,
            name: "testName",
            givingAtoms: givingAtoms,
            receivingAtoms: new Atom[](0),
            bond: bond,
            universeHash: universeInformation.seedHash,
            electricalConductivity: 1,
            thermalConductivity: 1,
            toughness: 1,
            hardness: 1,
            ductility: 1
        });

        string memory tokenUri = "test-uri";

        bytes32 miningMessageHash = encoder.getMiningMessageHash(
            molecule,
            creationHash,
            tokenUri,
            universeInformation.seedHash,
            expiry,
            address(eoa)
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            _signerKey,
            getMessageHash(miningMessageHash)
        );
        bytes memory createSignature = constructSignatureBytes(v2, r2, s2);

        vm.prank(eoa);

        MiningPayload[] memory payloads = new MiningPayload[](1);
        payloads[0] = MiningPayload({
            minedMolecule: molecule,
            miningHash: creationHash,
            tokenUri: tokenUri,
            universeHash: universeInformation.seedHash,
            expiry: expiry,
            signature: createSignature
        });

        otoms.mine(payloads);

        assertEq(
            otoms.totalSupply(database.idToTokenId(molecule.id)),
            1,
            "Total supply should be 1"
        );
        assertEq(
            otoms.balanceOf(eoa, database.idToTokenId(molecule.id)),
            1,
            "Eoa should be the owner of the token"
        );
    }

    function testFuzz_annihilate(uint256 nucleons) public {
        vm.assume(nucleons < 1000 * 1e18);
        //seed the universe
        bytes32 seedUniverseHash = encoder.getSeedUniverseMessageHash(
            universeInformation,
            expiry,
            address(eoa)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _signerKey,
            getMessageHash(seedUniverseHash)
        );
        bytes memory seedUniverseSignature = constructSignatureBytes(v, r, s);

        vm.prank(eoa);
        otoms.seedUniverse(universeInformation, expiry, seedUniverseSignature);

        uint256[] memory totalInOuter = new uint256[](2);
        totalInOuter[0] = 2;
        totalInOuter[1] = 2;

        uint256[] memory emptyInOuter = new uint256[](2);
        emptyInOuter[0] = 1;
        emptyInOuter[1] = 1;

        uint256[] memory filledInOuter = new uint256[](2);
        filledInOuter[0] = 2;
        filledInOuter[1] = 2;

        uint256[] memory ancestors = new uint256[](1);
        ancestors[0] = 1;

        AtomStructure memory structure = AtomStructure({
            universeHash: universeInformation.seedHash,
            depth: 3,
            distance: 4,
            distanceIndex: 4,
            shell: 2,
            totalInOuter: totalInOuter,
            emptyInOuter: emptyInOuter,
            filledInOuter: filledInOuter,
            ancestors: ancestors
        });

        Nucleus memory nucleus = Nucleus({
            protons: 6,
            neutrons: 6,
            nucleons: nucleons,
            stability: 40,
            decayType: "testDecay"
        });

        bytes32 creationHash = encoder.getMiningHash(
            address(eoa),
            universeInformation.seedHash,
            otoms.getMiningNonce(universeInformation.seedHash, address(eoa))
        );

        Bond memory bond = Bond({strength: 1, bondType: "testBondType"});

        Atom[] memory givingAtoms = new Atom[](1);
        givingAtoms[0] = Atom({
            radius: 4,
            volume: 10,
            mass: 100,
            density: 1,
            electronegativity: 1,
            name: "testName",
            structure: structure,
            nucleus: nucleus,
            metallic: false,
            series: "testSeries",
            periodicTableX: 1,
            periodicTableY: 1
        });

        Molecule memory molecule = Molecule({
            id: "a",
            activationEnergy: 1,
            radius: 4,
            name: "testName",
            givingAtoms: givingAtoms,
            receivingAtoms: new Atom[](0),
            bond: bond,
            universeHash: universeInformation.seedHash,
            electricalConductivity: 1,
            thermalConductivity: 1,
            toughness: 1,
            hardness: 1,
            ductility: 1
        });

        string memory tokenUri = "test-uri";

        bytes32 miningMessageHash = encoder.getMiningMessageHash(
            molecule,
            creationHash,
            tokenUri,
            universeInformation.seedHash,
            expiry,
            address(eoa)
        );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            _signerKey,
            getMessageHash(miningMessageHash)
        );
        bytes memory createSignature = constructSignatureBytes(v2, r2, s2);

        vm.prank(eoa);

        MiningPayload[] memory payloads = new MiningPayload[](1);
        payloads[0] = MiningPayload({
            minedMolecule: molecule,
            miningHash: creationHash,
            tokenUri: tokenUri,
            universeHash: universeInformation.seedHash,
            expiry: expiry,
            signature: createSignature
        });

        otoms.mine(payloads);

        uint256[] memory atomIds = new uint256[](1);
        atomIds[0] = database.idToTokenId(molecule.id);
        vm.prank(eoa);
        annihilator.annihilate(atomIds);
    }
}
