package com.sparrowwallet.sparrow.io;

import com.google.gson.Gson;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.LuminanceSource;
import com.google.zxing.client.j2se.BufferedImageLuminanceSource;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import com.sparrowwallet.bokmakierie.Bokmakierie;
import com.sparrowwallet.drongo.KeyPurpose;
import com.sparrowwallet.drongo.Network;
import com.sparrowwallet.drongo.OutputDescriptor;
import com.sparrowwallet.drongo.Utils;
import com.sparrowwallet.drongo.address.Address;
import com.sparrowwallet.drongo.protocol.Sha256Hash;
import com.sparrowwallet.drongo.protocol.Transaction;
import com.sparrowwallet.drongo.protocol.TransactionInput;
import com.sparrowwallet.drongo.protocol.TransactionOutput;
import com.sparrowwallet.drongo.psbt.PSBT;
import com.sparrowwallet.drongo.wallet.*;
import com.sparrowwallet.hummingbird.LegacyURDecoder;
import com.sparrowwallet.hummingbird.ResultType;
import com.sparrowwallet.hummingbird.UR;
import com.sparrowwallet.hummingbird.URDecoder;
import com.sparrowwallet.hummingbird.registry.RegistryType;
import com.sparrowwallet.sparrow.SparrowWallet;
import com.sparrowwallet.sparrow.wallet.WalletForm;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.function.Executable;
import org.junit.jupiter.api.io.TempDir;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.*;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Sparrow half of Birch's labels-QR harness (birch-wallet scripts/sparrow-labels-harness).
 *
 * Birch's SparrowLabelsQRHarnessTests writes, for a small and a realistic wallet, the frames its
 * Export QR shows plus everything needed to rebuild the same wallet. This test checks, in order,
 * what Sparrow does with them on File > Import Wallet > Labels > Scan...:
 *   1. its scanner reads every frame (WebcamService.readQR: bokmakierie, then ZXing),
 *   2. the UR decodes to the labels text and nothing else (QRScanDialog.extractResultFromUR),
 *   3. WalletLabels.importWallet applies every label to the matching wallet.
 *
 * run.sh copies this file and the artifacts into a Sparrow checkout, runs it, and removes them.
 */
public class BirchLabelsQRImportTest extends IoTest {
    private static final String BIRCH_PATH = "birch/";
    private static final List<String> SIZES = List.of("small", "realistic");

    @TempDir
    private static Path tempHome;

    @BeforeAll
    public static void setup() {
        //Isolate Config.get() from the developer's config, as WalletLabelsTest does
        System.setProperty(SparrowWallet.APP_HOME_PROPERTY, tempHome.toString());
        Network.set(Network.MAINNET);
    }

    @AfterAll
    public static void tearDown() {
        System.clearProperty(SparrowWallet.APP_HOME_PROPERTY);
    }

    @TestFactory
    public Stream<DynamicTest> birchLabelsQR() {
        return SIZES.stream().flatMap(size -> Stream.of(
                DynamicTest.dynamicTest(size + ": 1 scanner reads every frame", () -> testFramesScan(load(size))),
                DynamicTest.dynamicTest(size + ": 2 UR decodes to the labels text", () -> testScanResult(load(size))),
                DynamicTest.dynamicTest(size + ": 3 labels import into the wallet", () -> testImport(load(size)))));
    }

    // 1. WebcamService.readQR tries bokmakierie, then ZBar (off unless configured), then ZXing
    private void testFramesScan(Scenario scenario) throws Exception {
        Bokmakierie bokmakierie = null;
        try {
            bokmakierie = new Bokmakierie();
        } catch(Throwable e) {
            System.out.println("[" + scenario.size + "] bokmakierie unavailable, using ZXing only: " + e);
        }
        QRCodeReader zxing = new QRCodeReader();

        int byBokmakierie = 0;
        int byZxing = 0;
        List<String> failures = new ArrayList<>();
        for(int i = 0; i < scenario.framePNGs.size(); i++) {
            BufferedImage image;
            try(InputStream inputStream = getInputStream(BIRCH_PATH + scenario.framePNGs.get(i))) {
                image = ImageIO.read(inputStream);
            }

            String text = null;
            if(bokmakierie != null) {
                try {
                    com.sparrowwallet.bokmakierie.Result result = bokmakierie.scan(image);
                    if(result != null) {
                        text = result.getMessage();
                        byBokmakierie++;
                    }
                } catch(Exception e) {
                    //Sparrow logs and falls through
                }
            }
            if(text == null) {
                try {
                    LuminanceSource source = new BufferedImageLuminanceSource(image);
                    text = zxing.decode(new BinaryBitmap(new HybridBinarizer(source)), Map.of(DecodeHintType.TRY_HARDER, Boolean.TRUE)).getText();
                    byZxing++;
                } catch(Exception e) {
                    failures.add("frame " + i + " did not scan: " + e);
                    continue;
                }
            }

            if(!scenario.urParts.get(i).equals(text)) {
                failures.add("frame " + i + " scanned as '" + text + "', expected '" + scenario.urParts.get(i) + "'");
            }
        }

        System.out.println("[" + scenario.size + "] " + scenario.framePNGs.size() + " frames: " + byBokmakierie + " read by bokmakierie, " + byZxing + " by ZXing");
        Assertions.assertTrue(failures.isEmpty(), String.join("\n", failures));
    }

    // 2. QRScanDialog.QRResultListener feeds each frame to URDecoder; extractResultFromUR then tries
    // the bytes as a PSBT, then as a transaction, and only then as UTF-8 text (QRScanDialog.java:438-467)
    private void testScanResult(Scenario scenario) throws Exception {
        byte[] urBytes = decodeUR(scenario);

        boolean isPsbt;
        try {
            new PSBT(urBytes, false);
            isPsbt = true;
        } catch(Exception e) {
            isPsbt = false;
        }
        Assertions.assertFalse(isPsbt, "Sparrow would read the labels as a PSBT");

        Transaction transaction = null;
        try {
            transaction = new Transaction(urBytes);
        } catch(Exception e) {
            //Expected: the labels are not a transaction
        }
        if(transaction != null) {
            Assertions.fail("Sparrow would read the " + urBytes.length + " bytes of labels as a transaction (" + transaction.getInputs().size() + " inputs, "
                    + transaction.getOutputs().size() + " outputs, " + transaction.getLength() + " bytes parsed) and FileImportPane.importQR would show "
                    + "\"The scanned QR code does not contain a wallet or key.\" drongo's Transaction parser does not check that it used every byte.");
        }

        String text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(urBytes)).toString();
        Assertions.assertEquals(scenario.jsonl, text, "The UR should decode to Birch's JSONL");
    }

    // 3. FileWalletImportPane passes the scanned text to WalletLabels.importWallet
    private void testImport(Scenario scenario) throws Exception {
        TestWallet testWallet = buildWallet(scenario);
        Wallet wallet = testWallet.wallet;

        String text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(decodeUR(scenario))).toString();
        //Importing a keystore label needs the AppServices singleton, which is not available outside the UI (as in WalletLabelsTest)
        String importable = text.lines().filter(line -> !line.contains("\"type\":\"xpub\"")).collect(Collectors.joining("\n"));
        new WalletLabels(List.of(testWallet.walletForm)).importWallet(new ByteArrayInputStream(importable.getBytes(StandardCharsets.UTF_8)), null);

        Set<String> keystoreXpubs = wallet.getKeystores().stream().map(keystore -> keystore.getExtendedPublicKey().toString()).collect(Collectors.toSet());
        String sparrowOrigin = OutputDescriptor.getOutputDescriptor(wallet).toString(true, false, false);
        String birchOrigin = text.lines().filter(line -> line.contains("\"origin\"")).findFirst().map(line -> new Gson().fromJson(line, Map.class).get("origin").toString()).orElse("(none)");
        String originNote = "\nBirch origin:   " + birchOrigin + "\nSparrow origin: " + sparrowOrigin + "\n(Sparrow skips a label whose origin doesn't match the wallet's)";

        List<Executable> checks = new ArrayList<>();
        for(String xpub : scenario.expected.xpubs) {
            checks.add(() -> Assertions.assertTrue(keystoreXpubs.contains(xpub), "xpub label ref " + xpub + " matches no keystore in " + keystoreXpubs));
        }
        for(ExpectedLabel expected : scenario.expected.labels) {
            checks.add(() -> Assertions.assertEquals(expected.label, testWallet.labelOf(expected.type, expected.ref), expected.type + " " + expected.ref + originNote));
        }
        for(String outpoint : scenario.expected.frozen) {
            checks.add(() -> Assertions.assertEquals(Status.FROZEN, testWallet.txos.get(outpoint).getStatus(), "output " + outpoint + " should be frozen"));
        }
        for(String outpoint : scenario.expected.spendable) {
            checks.add(() -> Assertions.assertNull(testWallet.txos.get(outpoint).getStatus(), "output " + outpoint + " should stay spendable"));
        }
        Assertions.assertAll(checks);
    }

    // Hummingbird decoding as QRScanDialog.QRResultListener does it
    private byte[] decodeUR(Scenario scenario) throws Exception {
        URDecoder urDecoder = new URDecoder();
        for(String part : scenario.urParts) {
            Assertions.assertTrue(part.toLowerCase(Locale.ROOT).startsWith(UR.UR_PREFIX), "Frame is not a UR: " + part);
            Assertions.assertFalse(LegacyURDecoder.isLegacyURFragment(part), "Frame looks like a legacy UR fragment: " + part);
            urDecoder.receivePart(part);
            if(urDecoder.getResult() != null) {
                break;
            }
        }

        URDecoder.Result urResult = urDecoder.getResult();
        Assertions.assertNotNull(urResult, "The UR did not complete after " + scenario.urParts.size() + " frames (" + scenario.seqLen + " fragments)");
        Assertions.assertEquals(ResultType.SUCCESS, urResult.type, "UR decode failed: " + urResult.error);
        Assertions.assertEquals(RegistryType.BYTES, urResult.ur.getRegistryType());
        return (byte[])urResult.ur.decodeFromRegistry();
    }

    private TestWallet buildWallet(Scenario scenario) throws Exception {
        Wallet wallet = OutputDescriptor.getOutputDescriptor(scenario.descriptor).toWallet();
        wallet.setName("Birch harness " + scenario.size);
        wallet.setStoredBlockHeight(scenario.transactions.stream().mapToInt(tx -> tx.height).max().orElse(0) + 10);
        Assertions.assertTrue(wallet.isValid(), "Sparrow should build a valid wallet from the descriptor");

        Map<String, WalletNode> nodesByAddress = new HashMap<>();
        nodesByAddress.putAll(fillNodes(wallet, KeyPurpose.RECEIVE, scenario.receiveAddresses));
        nodesByAddress.putAll(fillNodes(wallet, KeyPurpose.CHANGE, scenario.changeAddresses));

        Map<Sha256Hash, BlockTransaction> blockTransactions = new LinkedHashMap<>();
        for(RawTransaction raw : scenario.transactions) {
            Transaction transaction = new Transaction(Utils.hexToBytes(raw.hex));
            Assertions.assertEquals(raw.txid, transaction.getTxId().toString(), "drongo and BDK should agree on the txid");
            blockTransactions.put(transaction.getTxId(), new BlockTransaction(transaction.getTxId(), raw.height, new Date(raw.time * 1000L), null, transaction));
        }
        wallet.updateTransactions(blockTransactions);

        //Spending inputs first, so each output is created with its spentBy (the node's TXO set is sorted)
        Map<String, BlockTransactionHashIndex> spentBy = new HashMap<>();
        for(BlockTransaction blkTx : blockTransactions.values()) {
            List<TransactionInput> inputs = blkTx.getTransaction().getInputs();
            for(int i = 0; i < inputs.size(); i++) {
                String outpoint = inputs.get(i).getOutpoint().getHash() + ":" + inputs.get(i).getOutpoint().getIndex();
                spentBy.put(outpoint, new BlockTransactionHashIndex(blkTx.getHash(), blkTx.getHeight(), blkTx.getDate(), null, i, 0L));
            }
        }

        Map<String, BlockTransactionHashIndex> txos = new HashMap<>();
        for(BlockTransaction blkTx : blockTransactions.values()) {
            List<TransactionOutput> outputs = blkTx.getTransaction().getOutputs();
            for(int i = 0; i < outputs.size(); i++) {
                Address address = outputs.get(i).getScript().getToAddress();
                WalletNode node = address == null ? null : nodesByAddress.get(address.toString());
                if(node == null) {
                    continue;
                }
                String outpoint = blkTx.getHash() + ":" + i;
                long value = outputs.get(i).getValue();
                BlockTransactionHashIndex spender = spentBy.get(outpoint);
                if(spender != null) {
                    spender = new BlockTransactionHashIndex(spender.getHash(), spender.getHeight(), spender.getDate(), null, spender.getIndex(), value);
                }
                BlockTransactionHashIndex txo = new BlockTransactionHashIndex(blkTx.getHash(), blkTx.getHeight(), blkTx.getDate(), null, i, value, spender);
                node.getTransactionOutputs().add(txo);
                txos.put(outpoint, txo);
            }
        }

        Storage storage = new Storage(PersistenceType.JSON, new File(tempHome.toFile(), "birch-" + scenario.size + ".json"));
        return new TestWallet(new WalletForm(storage, wallet), wallet, nodesByAddress, txos);
    }

    private Map<String, WalletNode> fillNodes(Wallet wallet, KeyPurpose keyPurpose, List<String> birchAddresses) {
        WalletNode purposeNode = wallet.getNode(keyPurpose);
        purposeNode.fillToIndex(wallet, birchAddresses.size() - 1);
        Map<Integer, WalletNode> byIndex = purposeNode.getChildren().stream().collect(Collectors.toMap(WalletNode::getIndex, node -> node));

        Map<String, WalletNode> nodesByAddress = new HashMap<>();
        for(int i = 0; i < birchAddresses.size(); i++) {
            String sparrowAddress = byIndex.get(i).getAddress().toString();
            Assertions.assertEquals(birchAddresses.get(i), sparrowAddress, keyPurpose + " address " + i + " should match between Birch and Sparrow");
            nodesByAddress.put(sparrowAddress, byIndex.get(i));
        }
        return nodesByAddress;
    }

    private Scenario load(String size) throws Exception {
        try(InputStreamReader reader = new InputStreamReader(getInputStream(BIRCH_PATH + "scenario-" + size + ".json"), StandardCharsets.UTF_8)) {
            return new Gson().fromJson(reader, Scenario.class);
        }
    }

    private record TestWallet(WalletForm walletForm, Wallet wallet, Map<String, WalletNode> nodesByAddress, Map<String, BlockTransactionHashIndex> txos) {
        String labelOf(String type, String ref) {
            return switch(type) {
                case "tx" -> wallet.getTransactions().get(Sha256Hash.wrap(ref)).getLabel();
                case "addr" -> nodesByAddress.get(ref).getLabel();
                case "output" -> txos.get(ref).getLabel();
                case "input" -> {
                    String[] spending = ref.split(":");
                    yield txos.values().stream().filter(txo -> txo.getSpentBy() != null && txo.getSpentBy().getHash().toString().equals(spending[0])
                            && txo.getSpentBy().getIndex() == Long.parseLong(spending[1])).findFirst().map(txo -> txo.getSpentBy().getLabel()).orElse(null);
                }
                default -> throw new IllegalArgumentException("Unknown label type " + type);
            };
        }
    }

    //Mirrors the JSON Birch writes (SparrowLabelsQRHarnessTests.Artifact)
    private static class Scenario {
        String size;
        String descriptor;
        List<String> receiveAddresses;
        List<String> changeAddresses;
        List<RawTransaction> transactions;
        String jsonl;
        int seqLen;
        List<String> urParts;
        List<String> framePNGs;
        Expected expected;
    }

    private static class RawTransaction {
        String txid;
        String hex;
        int height;
        long time;
    }

    private static class Expected {
        List<ExpectedLabel> labels;
        List<String> frozen;
        List<String> spendable;
        List<String> xpubs;
    }

    private static class ExpectedLabel {
        String type;
        String ref;
        String label;
    }
}
