package com.cloud.payflow;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Transaction API - the business surface of the workload plane.
 *
 * POST /transactions      create a transaction (writes to DynamoDB)
 * GET  /transactions/{id} fetch a transaction
 *
 * Fintech-flavored detail worth mentioning in the report: POST uses a
 * conditional write (attribute_not_exists) so a retried request with the same
 * client-supplied id cannot double-record a transaction - idempotency at the
 * data layer, the same principle the Triage remediation path uses.
 */
@RestController
@RequestMapping("/transactions")
public class TransactionController {

    private static final Logger log = LoggerFactory.getLogger(TransactionController.class);

    private final DynamoDbClient dynamo;
    private final String tableName;

    public TransactionController() {
        this.dynamo = DynamoDbClient.builder()
                .region(Region.of(System.getenv().getOrDefault("AWS_REGION", "us-east-1")))
                .build();
        this.tableName = System.getenv().getOrDefault("TABLE_NAME", "payflow-transactions");
    }

    @PostMapping
    public ResponseEntity<Map<String, String>> createTransaction(
            @RequestBody(required = false) Map<String, Object> body) {

        String txnId = body != null && body.get("txn_id") instanceof String s && !s.isBlank()
                ? s
                : UUID.randomUUID().toString();
        String amount = body != null && body.get("amount") != null
                ? String.valueOf(body.get("amount"))
                : "10.00";

        Map<String, AttributeValue> item = new HashMap<>();
        item.put("txn_id", AttributeValue.fromS(txnId));
        item.put("amount", AttributeValue.fromS(amount));
        item.put("status", AttributeValue.fromS("COMPLETED"));
        item.put("created_at", AttributeValue.fromS(Instant.now().toString()));

        try {
            dynamo.putItem(PutItemRequest.builder()
                    .tableName(tableName)
                    .item(item)
                    .conditionExpression("attribute_not_exists(txn_id)")
                    .build());
        } catch (ConditionalCheckFailedException e) {
            // Idempotent replay: the transaction already exists - return it, don't duplicate.
            log.info("Idempotent replay detected for txn_id={}", txnId);
            return ResponseEntity.ok(Map.of("txn_id", txnId, "status", "ALREADY_RECORDED"));
        }

        log.info("Transaction recorded txn_id={} amount={}", txnId, amount);
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(Map.of("txn_id", txnId, "status", "COMPLETED"));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Map<String, String>> getTransaction(@PathVariable("id") String id) {
        var result = dynamo.getItem(GetItemRequest.builder()
                .tableName(tableName)
                .key(Map.of("txn_id", AttributeValue.fromS(id)))
                .build());

        if (!result.hasItem() || result.item().isEmpty()) {
            return ResponseEntity.notFound().build();
        }

        Map<String, String> out = new HashMap<>();
        result.item().forEach((k, v) -> out.put(k, v.s()));
        return ResponseEntity.ok(out);
    }
}
